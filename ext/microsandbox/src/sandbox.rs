//! `Microsandbox::Native::Sandbox` — the single wrapped native class.
//!
//! Holds a core `microsandbox::Sandbox` (cheap to clone; Arc-based) and exposes
//! synchronous, primitive-typed methods. Filesystem operations are folded in as
//! `fs_*` methods rather than a separate wrapper class. Everything that isn't a
//! handle (exec output, metrics, log entries, fs entries/metadata) is returned
//! as a plain Ruby `Hash`/`Array`/`String` and shaped into value objects by the
//! Ruby layer.

use std::time::Duration;

use chrono::{DateTime, Utc};
use magnus::{function, method, prelude::*, Error, RArray, RHash, RModule, RString, Ruby};
use microsandbox::logs::{LogEntry, LogOptions, LogSource};
use microsandbox::sandbox::{
    FsEntry, FsEntryKind, FsMetadata, SandboxHandle, SandboxMetrics, SandboxStatus,
};

use crate::conv;
use crate::error;
use crate::runtime::block_on;

#[magnus::wrap(class = "Microsandbox::Native::Sandbox", free_immediately, size)]
pub struct Sandbox {
    inner: microsandbox::Sandbox,
}

impl Sandbox {
    fn from_inner(inner: microsandbox::Sandbox) -> Self {
        Self { inner }
    }

    //----------------------------------------------------------------------
    // Lifecycle (singleton methods)
    //----------------------------------------------------------------------

    /// Create and boot a sandbox. `opts` is a string-keyed options Hash.
    fn create(name: String, opts: RHash) -> Result<Sandbox, Error> {
        let mut b = microsandbox::Sandbox::builder(name);

        if let Some(v) = conv::opt_string(opts, "image")? {
            b = b.image(v);
        }
        if let Some(v) = conv::opt_u8(opts, "cpus")? {
            b = b.cpus(v);
        }
        if let Some(v) = conv::opt_u32(opts, "memory")? {
            b = b.memory(v);
        }
        if let Some(v) = conv::opt_string(opts, "workdir")? {
            b = b.workdir(v);
        }
        if let Some(v) = conv::opt_string(opts, "shell")? {
            b = b.shell(v);
        }
        if let Some(v) = conv::opt_string(opts, "user")? {
            b = b.user(v);
        }
        if let Some(v) = conv::opt_string(opts, "hostname")? {
            b = b.hostname(v);
        }
        for (k, v) in conv::opt_string_map(opts, "env")? {
            b = b.env(k, v);
        }
        for (k, v) in conv::opt_string_map(opts, "labels")? {
            b = b.label(k, v);
        }
        for (k, v) in conv::opt_string_map(opts, "scripts")? {
            b = b.script(k, v);
        }
        let entrypoint = conv::opt_string_vec(opts, "entrypoint")?;
        if !entrypoint.is_empty() {
            b = b.entrypoint(entrypoint);
        }
        for (host, guest) in conv::opt_port_map(opts, "ports")? {
            b = b.port(host, guest);
        }
        if let Some(net) = conv::opt_string(opts, "network")? {
            match net.as_str() {
                "none" | "disabled" | "disable" | "airgapped" => b = b.disable_network(),
                "public" | "public_only" | "all" | "default" => {}
                other => {
                    return Err(error::base_error(format!(
                        "unknown network mode {other:?} (expected \"public_only\" or \"none\")"
                    )))
                }
            }
        }
        if conv::opt_bool(opts, "detached")? {
            b = b.detached(true);
        }
        if let Some(secs) = conv::opt_f64(opts, "replace_with_timeout")? {
            b = b.replace_with_timeout(Duration::from_secs_f64(secs));
        } else if conv::opt_bool(opts, "replace")? {
            b = b.replace();
        }

        let inner = block_on(b.create()).map_err(error::to_ruby)?;
        Ok(Sandbox::from_inner(inner))
    }

    /// Restart a previously-defined sandbox by name.
    fn start(name: String, opts: RHash) -> Result<Sandbox, Error> {
        let detached = conv::opt_bool(opts, "detached")?;
        let inner = if detached {
            block_on(microsandbox::Sandbox::start_detached(&name)).map_err(error::to_ruby)?
        } else {
            block_on(microsandbox::Sandbox::start(&name)).map_err(error::to_ruby)?
        };
        Ok(Sandbox::from_inner(inner))
    }

    /// Lightweight metadata for a sandbox by name (running or not).
    fn get(name: String) -> Result<RHash, Error> {
        let handle = block_on(microsandbox::Sandbox::get(&name)).map_err(error::to_ruby)?;
        Ok(handle_to_hash(&handle))
    }

    /// All sandboxes as metadata hashes.
    fn list() -> Result<RArray, Error> {
        let handles = block_on(microsandbox::Sandbox::list()).map_err(error::to_ruby)?;
        rhash_array(handles.iter().map(handle_to_hash))
    }

    /// Remove a (stopped) sandbox by name.
    fn remove(name: String) -> Result<(), Error> {
        block_on(microsandbox::Sandbox::remove(&name)).map_err(error::to_ruby)
    }

    //----------------------------------------------------------------------
    // Instance methods
    //----------------------------------------------------------------------

    fn name(&self) -> String {
        self.inner.name().to_string()
    }

    /// Run a command (no shell). `args` is an Array of strings; `opts` is a
    /// string-keyed Hash (cwd, user, env, timeout, tty, stdin).
    fn exec(&self, cmd: String, args: Vec<String>, opts: RHash) -> Result<RHash, Error> {
        let parsed = ExecOpts::parse(args, opts)?;
        let output = block_on(self.inner.exec_with(cmd, move |b| parsed.apply(b)))
            .map_err(error::to_ruby)?;
        exec_output_to_hash(output)
    }

    /// Run a shell script (pipes/redirects allowed).
    fn shell(&self, script: String, opts: RHash) -> Result<RHash, Error> {
        let parsed = ExecOpts::parse(Vec::new(), opts)?;
        let output = block_on(self.inner.shell_with(script, move |b| parsed.apply(b)))
            .map_err(error::to_ruby)?;
        exec_output_to_hash(output)
    }

    /// Graceful stop (+ wait). `timeout` is optional seconds.
    fn stop(&self, timeout: Option<f64>) -> Result<(), Error> {
        match timeout {
            Some(secs) => block_on(self.inner.stop_with_timeout(Duration::from_secs_f64(secs))),
            None => block_on(self.inner.stop()),
        }
        .map_err(error::to_ruby)
    }

    /// Force kill (SIGKILL). `timeout` is optional seconds.
    fn kill(&self, timeout: Option<f64>) -> Result<(), Error> {
        match timeout {
            Some(secs) => block_on(self.inner.kill_with_timeout(Duration::from_secs_f64(secs))),
            None => block_on(self.inner.kill()),
        }
        .map_err(error::to_ruby)
    }

    /// Latest metrics snapshot as a Hash.
    fn metrics(&self) -> Result<RHash, Error> {
        let m = block_on(self.inner.metrics()).map_err(error::to_ruby)?;
        Ok(metrics_to_hash(&m))
    }

    /// Read captured logs as an Array of Hashes. `opts`: tail, since_ms,
    /// until_ms, sources (Array of "stdout"/"stderr"/"output"/"system"/"all").
    fn logs(&self, opts: RHash) -> Result<RArray, Error> {
        let log_opts = parse_log_options(opts)?;
        let entries = block_on(self.inner.logs(&log_opts)).map_err(error::to_ruby)?;
        rhash_array(entries.iter().map(log_entry_to_hash))
    }

    //----------------------------------------------------------------------
    // Filesystem (folded in; mirror SandboxFsOps)
    //----------------------------------------------------------------------

    fn fs_read(&self, path: String) -> Result<RString, Error> {
        let fs = self.inner.fs();
        let bytes = block_on(fs.read(&path)).map_err(error::to_ruby)?;
        Ok(ruby().str_from_slice(bytes.as_ref()))
    }

    fn fs_read_text(&self, path: String) -> Result<String, Error> {
        let fs = self.inner.fs();
        block_on(fs.read_to_string(&path)).map_err(error::to_ruby)
    }

    fn fs_write(&self, path: String, data: RString) -> Result<(), Error> {
        // Copy out of the Ruby string while we still hold the GVL: the buffer
        // could be moved/freed by GC.compact once block_on releases it.
        let bytes = unsafe { data.as_slice() }.to_vec();
        let fs = self.inner.fs();
        block_on(fs.write(&path, &bytes)).map_err(error::to_ruby)
    }

    fn fs_list(&self, path: String) -> Result<RArray, Error> {
        let fs = self.inner.fs();
        let entries = block_on(fs.list(&path)).map_err(error::to_ruby)?;
        rhash_array(entries.iter().map(fs_entry_to_hash))
    }

    fn fs_mkdir(&self, path: String) -> Result<(), Error> {
        let fs = self.inner.fs();
        block_on(fs.mkdir(&path)).map_err(error::to_ruby)
    }

    fn fs_remove(&self, path: String) -> Result<(), Error> {
        let fs = self.inner.fs();
        block_on(fs.remove(&path)).map_err(error::to_ruby)
    }

    fn fs_remove_dir(&self, path: String) -> Result<(), Error> {
        let fs = self.inner.fs();
        block_on(fs.remove_dir(&path)).map_err(error::to_ruby)
    }

    fn fs_copy(&self, src: String, dst: String) -> Result<(), Error> {
        let fs = self.inner.fs();
        block_on(fs.copy(&src, &dst)).map_err(error::to_ruby)
    }

    fn fs_rename(&self, src: String, dst: String) -> Result<(), Error> {
        let fs = self.inner.fs();
        block_on(fs.rename(&src, &dst)).map_err(error::to_ruby)
    }

    fn fs_exists(&self, path: String) -> Result<bool, Error> {
        let fs = self.inner.fs();
        block_on(fs.exists(&path)).map_err(error::to_ruby)
    }

    fn fs_stat(&self, path: String) -> Result<RHash, Error> {
        let fs = self.inner.fs();
        let meta = block_on(fs.stat(&path)).map_err(error::to_ruby)?;
        Ok(fs_metadata_to_hash(&meta))
    }

    fn fs_copy_from_host(&self, host_path: String, guest_path: String) -> Result<(), Error> {
        let fs = self.inner.fs();
        block_on(fs.copy_from_host(&host_path, &guest_path)).map_err(error::to_ruby)
    }

    fn fs_copy_to_host(&self, guest_path: String, host_path: String) -> Result<(), Error> {
        let fs = self.inner.fs();
        block_on(fs.copy_to_host(&guest_path, &host_path)).map_err(error::to_ruby)
    }
}

//--------------------------------------------------------------------------------------------------
// Exec option parsing
//--------------------------------------------------------------------------------------------------

struct ExecOpts {
    args: Vec<String>,
    cwd: Option<String>,
    user: Option<String>,
    env: Vec<(String, String)>,
    timeout: Option<Duration>,
    tty: bool,
    stdin: Option<Vec<u8>>,
}

impl ExecOpts {
    fn parse(args: Vec<String>, opts: RHash) -> Result<Self, Error> {
        let stdin = conv::opt::<RString>(opts, "stdin")?.map(|s| unsafe { s.as_slice() }.to_vec());
        Ok(Self {
            args,
            cwd: conv::opt_string(opts, "cwd")?,
            user: conv::opt_string(opts, "user")?,
            env: conv::opt_string_map(opts, "env")?,
            timeout: conv::opt_f64(opts, "timeout")?.map(Duration::from_secs_f64),
            tty: conv::opt_bool(opts, "tty")?,
            stdin,
        })
    }

    fn apply(
        self,
        mut b: microsandbox::sandbox::exec::ExecOptionsBuilder,
    ) -> microsandbox::sandbox::exec::ExecOptionsBuilder {
        if !self.args.is_empty() {
            b = b.args(self.args);
        }
        if let Some(cwd) = self.cwd {
            b = b.cwd(cwd);
        }
        if let Some(user) = self.user {
            b = b.user(user);
        }
        for (k, v) in self.env {
            b = b.env(k, v);
        }
        if let Some(timeout) = self.timeout {
            b = b.timeout(timeout);
        }
        if self.tty {
            b = b.tty(true);
        }
        if let Some(stdin) = self.stdin {
            b = b.stdin_bytes(stdin);
        }
        b
    }
}

//--------------------------------------------------------------------------------------------------
// Value conversions
//--------------------------------------------------------------------------------------------------

/// The current Ruby handle. Safe to call from any bound method: we always hold
/// the GVL at conversion time (after `block_on` has returned).
fn ruby() -> Ruby {
    Ruby::get().expect("microsandbox: value conversion off the Ruby thread")
}

/// Collect an iterator of `RHash` into a Ruby `Array`.
fn rhash_array<I: IntoIterator<Item = RHash>>(items: I) -> Result<RArray, Error> {
    let arr = ruby().ary_new();
    for item in items {
        arr.push(item)?;
    }
    Ok(arr)
}

fn exec_output_to_hash(output: microsandbox::ExecOutput) -> Result<RHash, Error> {
    let ruby = ruby();
    let hash = ruby.hash_new();
    let status = output.status();
    hash.aset("exit_code", status.code)?;
    hash.aset("success", status.success)?;
    hash.aset(
        "stdout",
        ruby.str_from_slice(output.stdout_bytes().as_ref()),
    )?;
    hash.aset(
        "stderr",
        ruby.str_from_slice(output.stderr_bytes().as_ref()),
    )?;
    Ok(hash)
}

fn fs_entry_kind_str(kind: FsEntryKind) -> &'static str {
    match kind {
        FsEntryKind::File => "file",
        FsEntryKind::Directory => "directory",
        FsEntryKind::Symlink => "symlink",
        FsEntryKind::Other => "other",
    }
}

fn fs_entry_to_hash(entry: &FsEntry) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("path", entry.path.clone());
    let _ = hash.aset("type", fs_entry_kind_str(entry.kind));
    let _ = hash.aset("size", entry.size);
    let _ = hash.aset("mode", entry.mode);
    let _ = hash.aset(
        "modified_ms",
        entry.modified.map(|dt| dt.timestamp_millis()),
    );
    hash
}

fn fs_metadata_to_hash(meta: &FsMetadata) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("type", fs_entry_kind_str(meta.kind));
    let _ = hash.aset("size", meta.size);
    let _ = hash.aset("mode", meta.mode);
    let _ = hash.aset("readonly", meta.readonly);
    let _ = hash.aset("modified_ms", meta.modified.map(|dt| dt.timestamp_millis()));
    let _ = hash.aset("created_ms", meta.created.map(|dt| dt.timestamp_millis()));
    hash
}

fn metrics_to_hash(m: &SandboxMetrics) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("cpu_percent", m.cpu_percent as f64);
    let _ = hash.aset("vcpu_time_ns", m.vcpu_time_ns);
    let _ = hash.aset("memory_bytes", m.memory_bytes);
    let _ = hash.aset("memory_available_bytes", m.memory_available_bytes);
    let _ = hash.aset("memory_host_resident_bytes", m.memory_host_resident_bytes);
    let _ = hash.aset("memory_limit_bytes", m.memory_limit_bytes);
    let _ = hash.aset("disk_read_bytes", m.disk_read_bytes);
    let _ = hash.aset("disk_write_bytes", m.disk_write_bytes);
    let _ = hash.aset("net_rx_bytes", m.net_rx_bytes);
    let _ = hash.aset("net_tx_bytes", m.net_tx_bytes);
    let _ = hash.aset("uptime_secs", m.uptime.as_secs_f64());
    let _ = hash.aset("timestamp_ms", m.timestamp.timestamp_millis());
    hash
}

fn sandbox_status_str(status: SandboxStatus) -> &'static str {
    match status {
        SandboxStatus::Running => "running",
        SandboxStatus::Draining => "draining",
        SandboxStatus::Paused => "paused",
        SandboxStatus::Stopped => "stopped",
        SandboxStatus::Crashed => "crashed",
    }
}

fn handle_to_hash(handle: &SandboxHandle) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("name", handle.name().to_string());
    let _ = hash.aset("status", sandbox_status_str(handle.status()));
    let _ = hash.aset(
        "created_at_ms",
        handle.created_at().map(|dt| dt.timestamp_millis()),
    );
    let _ = hash.aset(
        "updated_at_ms",
        handle.updated_at().map(|dt| dt.timestamp_millis()),
    );
    hash
}

//--------------------------------------------------------------------------------------------------
// Log option parsing
//--------------------------------------------------------------------------------------------------

fn ms_to_datetime(ms: f64) -> Option<DateTime<Utc>> {
    let secs = (ms / 1000.0).trunc() as i64;
    let nsecs = ((ms - secs as f64 * 1000.0) * 1_000_000.0).round() as u32;
    DateTime::from_timestamp(secs, nsecs)
}

fn parse_log_sources(opts: RHash) -> Result<Vec<LogSource>, Error> {
    let mut sources = Vec::new();
    for s in conv::opt_string_vec(opts, "sources")? {
        match s.as_str() {
            "stdout" => sources.push(LogSource::Stdout),
            "stderr" => sources.push(LogSource::Stderr),
            "output" => sources.push(LogSource::Output),
            "system" => sources.push(LogSource::System),
            "all" => {
                sources = vec![
                    LogSource::Stdout,
                    LogSource::Stderr,
                    LogSource::Output,
                    LogSource::System,
                ];
            }
            other => return Err(error::base_error(format!("unknown log source {other:?}"))),
        }
    }
    Ok(sources)
}

fn parse_log_options(opts: RHash) -> Result<LogOptions, Error> {
    Ok(LogOptions {
        tail: conv::opt::<usize>(opts, "tail")?,
        since: conv::opt_f64(opts, "since_ms")?.and_then(ms_to_datetime),
        until: conv::opt_f64(opts, "until_ms")?.and_then(ms_to_datetime),
        sources: parse_log_sources(opts)?,
    })
}

fn log_entry_to_hash(entry: &LogEntry) -> RHash {
    let source = match entry.source {
        LogSource::Stdout => "stdout",
        LogSource::Stderr => "stderr",
        LogSource::Output => "output",
        LogSource::System => "system",
    };
    let r = ruby();
    let hash = r.hash_new();
    let _ = hash.aset("timestamp_ms", entry.timestamp.timestamp_millis());
    let _ = hash.aset("source", source);
    let _ = hash.aset("session_id", entry.session_id);
    let _ = hash.aset("cursor", entry.cursor.to_string());
    let _ = hash.aset("data", r.str_from_slice(entry.data.as_ref()));
    hash
}

//--------------------------------------------------------------------------------------------------
// Registration
//--------------------------------------------------------------------------------------------------

pub fn define(ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    let class = native.define_class("Sandbox", ruby.class_object())?;

    class.define_singleton_method("create", function!(Sandbox::create, 2))?;
    class.define_singleton_method("start", function!(Sandbox::start, 2))?;
    class.define_singleton_method("get", function!(Sandbox::get, 1))?;
    class.define_singleton_method("list", function!(Sandbox::list, 0))?;
    class.define_singleton_method("remove", function!(Sandbox::remove, 1))?;

    class.define_method("name", method!(Sandbox::name, 0))?;
    class.define_method("exec", method!(Sandbox::exec, 3))?;
    class.define_method("shell", method!(Sandbox::shell, 2))?;
    class.define_method("stop", method!(Sandbox::stop, 1))?;
    class.define_method("kill", method!(Sandbox::kill, 1))?;
    class.define_method("metrics", method!(Sandbox::metrics, 0))?;
    class.define_method("logs", method!(Sandbox::logs, 1))?;

    class.define_method("fs_read", method!(Sandbox::fs_read, 1))?;
    class.define_method("fs_read_text", method!(Sandbox::fs_read_text, 1))?;
    class.define_method("fs_write", method!(Sandbox::fs_write, 2))?;
    class.define_method("fs_list", method!(Sandbox::fs_list, 1))?;
    class.define_method("fs_mkdir", method!(Sandbox::fs_mkdir, 1))?;
    class.define_method("fs_remove", method!(Sandbox::fs_remove, 1))?;
    class.define_method("fs_remove_dir", method!(Sandbox::fs_remove_dir, 1))?;
    class.define_method("fs_copy", method!(Sandbox::fs_copy, 2))?;
    class.define_method("fs_rename", method!(Sandbox::fs_rename, 2))?;
    class.define_method("fs_exists", method!(Sandbox::fs_exists, 1))?;
    class.define_method("fs_stat", method!(Sandbox::fs_stat, 1))?;
    class.define_method("fs_copy_from_host", method!(Sandbox::fs_copy_from_host, 2))?;
    class.define_method("fs_copy_to_host", method!(Sandbox::fs_copy_to_host, 2))?;

    Ok(())
}
