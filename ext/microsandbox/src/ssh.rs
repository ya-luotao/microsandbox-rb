//! SSH over a sandbox: `Microsandbox::Native::{SshClient, SftpClient, SshServer}`.
//!
//! Mirrors `sdk/python/src/ssh.rs`. The SSH ops are reached from the sandbox
//! (`Sandbox::ssh_open_client` / `ssh_prepare_server` in `sandbox.rs`); this
//! module holds the session wrappers. Each owns its core session behind an
//! `Arc<tokio::Mutex<Option<…>>>` so it can be consumed exactly once on close.
//!
//! Discipline: the async work runs inside `block_on` (GVL released), so it must
//! never touch the Ruby C API. Each method drives the future to a plain Rust
//! `Result`, then maps it to a Ruby exception *after* `block_on` returns.

use std::sync::Arc;

use magnus::{method, prelude::*, Error, RHash, RModule, RString, Ruby};
use microsandbox::sandbox::{
    SftpClient as CoreSftp, SshClient as CoreSshClient, SshOutput, SshServer as CoreSshServer,
    SshStdioStream,
};
use microsandbox::{MicrosandboxError, MicrosandboxResult};
use tokio::io::AsyncWriteExt;
use tokio::sync::Mutex;

use crate::error;
use crate::runtime::{block_on, ruby};

/// A core error for a session whose value was already taken (closed). Built
/// inside `block_on`, so it must be a plain Rust error, not a Ruby one.
fn consumed() -> MicrosandboxError {
    MicrosandboxError::Custom("SSH session is already closed".into())
}

//--------------------------------------------------------------------------------------------------
// SshClient
//--------------------------------------------------------------------------------------------------

#[magnus::wrap(class = "Microsandbox::Native::SshClient", free_immediately, size)]
pub struct SshClient {
    inner: Arc<Mutex<Option<CoreSshClient>>>,
}

impl SshClient {
    pub fn from_core(inner: CoreSshClient) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Some(inner))),
        }
    }

    /// Run a command over SSH and collect {status, stdout, stderr}.
    fn exec(&self, command: String, tty: bool) -> Result<RHash, Error> {
        let inner = Arc::clone(&self.inner);
        let result: MicrosandboxResult<SshOutput> = block_on(async move {
            let guard = inner.lock().await;
            let client = guard.as_ref().ok_or_else(consumed)?;
            client.exec_with(command, |b| b.tty(tty)).await
        });
        Ok(ssh_output_to_hash(result.map_err(error::to_ruby)?))
    }

    /// Attach the local terminal to an interactive SSH shell; returns the exit
    /// status. Host-TTY coupled (raw mode); not meaningful without a real tty.
    fn attach(&self, term: Option<String>, detach_keys: Option<String>) -> Result<i32, Error> {
        let inner = Arc::clone(&self.inner);
        let result: MicrosandboxResult<i32> = block_on(async move {
            let guard = inner.lock().await;
            let client = guard.as_ref().ok_or_else(consumed)?;
            client
                .attach_with(|mut b| {
                    if let Some(t) = term {
                        b = b.term(t);
                    }
                    if let Some(k) = detach_keys {
                        b = b.detach_keys(k);
                    }
                    b
                })
                .await
        });
        result.map_err(error::to_ruby)
    }

    /// Open an SFTP session over this SSH connection.
    fn sftp(&self) -> Result<SftpClient, Error> {
        let inner = Arc::clone(&self.inner);
        let result: MicrosandboxResult<CoreSftp> = block_on(async move {
            let guard = inner.lock().await;
            let client = guard.as_ref().ok_or_else(consumed)?;
            client.sftp().await
        });
        Ok(SftpClient::from_core(result.map_err(error::to_ruby)?))
    }

    /// Close the SSH client session. Idempotent.
    fn close(&self) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        let result: MicrosandboxResult<()> = block_on(async move {
            let client = {
                let mut guard = inner.lock().await;
                guard.take()
            };
            match client {
                Some(c) => c.close().await,
                None => Ok(()),
            }
        });
        result.map_err(error::to_ruby)
    }
}

fn ssh_output_to_hash(output: SshOutput) -> RHash {
    let r = ruby();
    let hash = r.hash_new();
    let _ = hash.aset("status", output.status);
    let _ = hash.aset("success", output.status == 0);
    let _ = hash.aset("stdout", r.str_from_slice(output.stdout.as_ref()));
    let _ = hash.aset("stderr", r.str_from_slice(output.stderr.as_ref()));
    hash
}

//--------------------------------------------------------------------------------------------------
// SftpClient
//--------------------------------------------------------------------------------------------------

#[magnus::wrap(class = "Microsandbox::Native::SftpClient", free_immediately, size)]
pub struct SftpClient {
    inner: Arc<Mutex<Option<CoreSftp>>>,
}

/// Format an SFTP-layer error as a plain string inside `block_on`; the Ruby
/// exception is built from it afterward.
fn sftp_str(e: impl std::fmt::Display) -> String {
    format!("SFTP error: {e}")
}

impl SftpClient {
    pub fn from_core(inner: CoreSftp) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Some(inner))),
        }
    }

    fn read(&self, path: String) -> Result<RString, Error> {
        let inner = Arc::clone(&self.inner);
        let result: Result<Vec<u8>, String> = block_on(async move {
            let guard = inner.lock().await;
            let sftp = guard.as_ref().ok_or_else(|| sftp_str("session closed"))?;
            sftp.read(path).await.map_err(sftp_str)
        });
        Ok(ruby().str_from_slice(&result.map_err(error::base_error)?))
    }

    fn write(&self, path: String, data: RString) -> Result<(), Error> {
        let bytes = unsafe { data.as_slice() }.to_vec();
        let inner = Arc::clone(&self.inner);
        let result: Result<(), String> = block_on(async move {
            let guard = inner.lock().await;
            let sftp = guard.as_ref().ok_or_else(|| sftp_str("session closed"))?;
            let mut file = sftp.create(path).await.map_err(sftp_str)?;
            file.write_all(&bytes).await.map_err(sftp_str)?;
            file.shutdown().await.map_err(sftp_str)?;
            Ok(())
        });
        result.map_err(error::base_error)
    }

    fn mkdir(&self, path: String) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        let result: Result<(), String> = block_on(async move {
            let guard = inner.lock().await;
            let sftp = guard.as_ref().ok_or_else(|| sftp_str("session closed"))?;
            sftp.create_dir(path).await.map_err(sftp_str)
        });
        result.map_err(error::base_error)
    }

    fn remove_file(&self, path: String) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        let result: Result<(), String> = block_on(async move {
            let guard = inner.lock().await;
            let sftp = guard.as_ref().ok_or_else(|| sftp_str("session closed"))?;
            sftp.remove_file(path).await.map_err(sftp_str)
        });
        result.map_err(error::base_error)
    }

    fn remove_dir(&self, path: String) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        let result: Result<(), String> = block_on(async move {
            let guard = inner.lock().await;
            let sftp = guard.as_ref().ok_or_else(|| sftp_str("session closed"))?;
            sftp.remove_dir(path).await.map_err(sftp_str)
        });
        result.map_err(error::base_error)
    }

    fn rename(&self, old_path: String, new_path: String) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        let result: Result<(), String> = block_on(async move {
            let guard = inner.lock().await;
            let sftp = guard.as_ref().ok_or_else(|| sftp_str("session closed"))?;
            sftp.rename(old_path, new_path).await.map_err(sftp_str)
        });
        result.map_err(error::base_error)
    }

    fn symlink(&self, target: String, link_path: String) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        let result: Result<(), String> = block_on(async move {
            let guard = inner.lock().await;
            let sftp = guard.as_ref().ok_or_else(|| sftp_str("session closed"))?;
            sftp.symlink(target, link_path).await.map_err(sftp_str)
        });
        result.map_err(error::base_error)
    }

    fn real_path(&self, path: String) -> Result<String, Error> {
        let inner = Arc::clone(&self.inner);
        let result: Result<String, String> = block_on(async move {
            let guard = inner.lock().await;
            let sftp = guard.as_ref().ok_or_else(|| sftp_str("session closed"))?;
            sftp.canonicalize(path).await.map_err(sftp_str)
        });
        result.map_err(error::base_error)
    }

    fn read_link(&self, path: String) -> Result<String, Error> {
        let inner = Arc::clone(&self.inner);
        let result: Result<String, String> = block_on(async move {
            let guard = inner.lock().await;
            let sftp = guard.as_ref().ok_or_else(|| sftp_str("session closed"))?;
            sftp.read_link(path).await.map_err(sftp_str)
        });
        result.map_err(error::base_error)
    }

    fn close(&self) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        let result: Result<(), String> = block_on(async move {
            let sftp = {
                let mut guard = inner.lock().await;
                guard.take()
            };
            match sftp {
                Some(s) => s.close().await.map_err(sftp_str),
                None => Ok(()),
            }
        });
        result.map_err(error::base_error)
    }
}

//--------------------------------------------------------------------------------------------------
// SshServer
//--------------------------------------------------------------------------------------------------

#[magnus::wrap(class = "Microsandbox::Native::SshServer", free_immediately, size)]
pub struct SshServer {
    inner: Arc<Mutex<Option<CoreSshServer>>>,
}

impl SshServer {
    pub fn from_core(inner: CoreSshServer) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Some(inner))),
        }
    }

    /// Serve one SSH connection over this process's stdin/stdout.
    fn serve_connection(&self) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        let result: MicrosandboxResult<()> = block_on(async move {
            let server = {
                let guard = inner.lock().await;
                guard.as_ref().cloned()
            };
            match server {
                Some(s) => s.serve_connection(SshStdioStream::new()).await,
                None => Err(consumed()),
            }
        });
        result.map_err(error::to_ruby)
    }

    /// Release the prepared server endpoint. Idempotent.
    fn close(&self) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        block_on(async move {
            inner.lock().await.take();
        });
        Ok(())
    }
}

pub fn define(ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    let client = native.define_class("SshClient", ruby.class_object())?;
    client.define_method("exec", method!(SshClient::exec, 2))?;
    client.define_method("attach", method!(SshClient::attach, 2))?;
    client.define_method("sftp", method!(SshClient::sftp, 0))?;
    client.define_method("close", method!(SshClient::close, 0))?;

    let sftp = native.define_class("SftpClient", ruby.class_object())?;
    sftp.define_method("read", method!(SftpClient::read, 1))?;
    sftp.define_method("write", method!(SftpClient::write, 2))?;
    sftp.define_method("mkdir", method!(SftpClient::mkdir, 1))?;
    sftp.define_method("remove_file", method!(SftpClient::remove_file, 1))?;
    sftp.define_method("remove_dir", method!(SftpClient::remove_dir, 1))?;
    sftp.define_method("rename", method!(SftpClient::rename, 2))?;
    sftp.define_method("symlink", method!(SftpClient::symlink, 2))?;
    sftp.define_method("real_path", method!(SftpClient::real_path, 1))?;
    sftp.define_method("read_link", method!(SftpClient::read_link, 1))?;
    sftp.define_method("close", method!(SftpClient::close, 0))?;

    let server = native.define_class("SshServer", ruby.class_object())?;
    server.define_method("serve_connection", method!(SshServer::serve_connection, 0))?;
    server.define_method("close", method!(SshServer::close, 0))?;

    Ok(())
}
