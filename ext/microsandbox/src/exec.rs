//! Streaming command execution: `Microsandbox::Native::ExecHandle` and
//! `Microsandbox::Native::ExecSink`.
//!
//! Mirrors `sdk/python/src/exec.rs`. The core `ExecHandle` is `&mut`-driven and
//! lives behind an `Arc<tokio::Mutex<…>>`; each call locks it inside `block_on`.
//! Signal/kill go through a cloned `ExecControl` so they never contend with an
//! in-flight `recv`. Stdin (when piped) is exposed as a separate `ExecSink`.

use std::sync::Arc;

use magnus::{method, prelude::*, Error, RHash, RModule, RString, Ruby};
use tokio::sync::Mutex;

use crate::error;
use crate::runtime::{block_on, ruby};

#[magnus::wrap(class = "Microsandbox::Native::ExecHandle", free_immediately, size)]
pub struct ExecHandle {
    inner: Arc<Mutex<microsandbox::ExecHandle>>,
    control: microsandbox::ExecControl,
    stdin: std::sync::Mutex<Option<Arc<microsandbox::sandbox::exec::ExecSink>>>,
    id: String,
}

impl ExecHandle {
    /// Wrap a freshly-opened core handle, lifting out its id and stdin sink.
    pub fn from_core(mut handle: microsandbox::ExecHandle) -> Self {
        let id = handle.id();
        let control = handle.control();
        let stdin = handle.take_stdin().map(Arc::new);
        Self {
            inner: Arc::new(Mutex::new(handle)),
            control,
            stdin: std::sync::Mutex::new(stdin),
            id,
        }
    }

    fn id(&self) -> String {
        self.id.clone()
    }

    /// Next event as a Hash, or nil when the stream ends.
    fn recv(&self) -> Result<Option<RHash>, Error> {
        let inner = Arc::clone(&self.inner);
        let event = block_on(async move { inner.lock().await.recv().await });
        Ok(event.map(exec_event_to_hash))
    }

    /// Block until exit; returns {exit_code, success}.
    fn wait(&self) -> Result<RHash, Error> {
        let inner = Arc::clone(&self.inner);
        let status =
            block_on(async move { inner.lock().await.wait().await }).map_err(error::to_ruby)?;
        let hash = ruby().hash_new();
        hash.aset("exit_code", status.code)?;
        hash.aset("success", status.success)?;
        Ok(hash)
    }

    /// Drain the stream and return a collected exec-output Hash.
    fn collect(&self) -> Result<RHash, Error> {
        let inner = Arc::clone(&self.inner);
        let output =
            block_on(async move { inner.lock().await.collect().await }).map_err(error::to_ruby)?;
        crate::sandbox::exec_output_to_hash(output)
    }

    fn signal(&self, sig: i32) -> Result<(), Error> {
        block_on(self.control.signal(sig)).map_err(error::to_ruby)
    }

    fn kill(&self) -> Result<(), Error> {
        block_on(self.control.kill()).map_err(error::to_ruby)
    }

    fn resize(&self, rows: u16, cols: u16) -> Result<(), Error> {
        block_on(self.control.resize(rows, cols)).map_err(error::to_ruby)
    }

    /// The stdin sink (only the first call returns it; nil afterwards or if
    /// stdin was not piped).
    fn take_stdin(&self) -> Option<ExecSink> {
        let mut guard = self.stdin.lock().expect("exec stdin mutex poisoned");
        guard.take().map(|sink| ExecSink { inner: sink })
    }
}

#[magnus::wrap(class = "Microsandbox::Native::ExecSink", free_immediately, size)]
pub struct ExecSink {
    inner: Arc<microsandbox::sandbox::exec::ExecSink>,
}

impl ExecSink {
    fn write(&self, data: RString) -> Result<(), Error> {
        // Copy out while holding the GVL (see sandbox::fs_write for the rationale).
        let bytes = unsafe { data.as_slice() }.to_vec();
        block_on(self.inner.write(&bytes)).map_err(error::to_ruby)
    }

    fn close(&self) -> Result<(), Error> {
        block_on(self.inner.close()).map_err(error::to_ruby)
    }
}

/// Convert a core `ExecEvent` into a Ruby Hash. `data` is binary (ASCII-8BIT).
fn exec_event_to_hash(event: microsandbox::ExecEvent) -> RHash {
    use microsandbox::ExecEvent::*;
    let r = ruby();
    let hash = r.hash_new();
    match event {
        Started { pid } => {
            let _ = hash.aset("type", "started");
            let _ = hash.aset("pid", pid);
        }
        Stdout(data) => {
            let _ = hash.aset("type", "stdout");
            let _ = hash.aset("data", r.str_from_slice(data.as_ref()));
        }
        Stderr(data) => {
            let _ = hash.aset("type", "stderr");
            let _ = hash.aset("data", r.str_from_slice(data.as_ref()));
        }
        Exited { code } => {
            let _ = hash.aset("type", "exited");
            let _ = hash.aset("code", code);
        }
        Failed(payload) => {
            let _ = hash.aset("type", "failed");
            let _ = hash.aset("data", r.str_from_slice(payload.message.as_bytes()));
            let _ = hash.aset("code", payload.errno);
        }
        StdinError(payload) => {
            let _ = hash.aset("type", "stdin_error");
            let _ = hash.aset("data", r.str_from_slice(payload.message.as_bytes()));
            let _ = hash.aset("code", payload.errno);
        }
    }
    hash
}

pub fn define(ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    let handle = native.define_class("ExecHandle", ruby.class_object())?;
    handle.define_method("id", method!(ExecHandle::id, 0))?;
    handle.define_method("recv", method!(ExecHandle::recv, 0))?;
    handle.define_method("wait", method!(ExecHandle::wait, 0))?;
    handle.define_method("collect", method!(ExecHandle::collect, 0))?;
    handle.define_method("signal", method!(ExecHandle::signal, 1))?;
    handle.define_method("kill", method!(ExecHandle::kill, 0))?;
    handle.define_method("resize", method!(ExecHandle::resize, 2))?;
    handle.define_method("take_stdin", method!(ExecHandle::take_stdin, 0))?;

    let sink = native.define_class("ExecSink", ruby.class_object())?;
    sink.define_method("write", method!(ExecSink::write, 1))?;
    sink.define_method("close", method!(ExecSink::close, 0))?;

    Ok(())
}
