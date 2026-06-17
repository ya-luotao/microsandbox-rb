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
use microsandbox::logs::{
    LogCursor, LogEntry, LogOptions, LogSource, LogStreamOptions, LogStreamStart,
};
use microsandbox::sandbox::{
    FsEntry, FsEntryKind, FsMetadata, PullPolicy, RlimitResource, SandboxFilter, SandboxHandle,
    SandboxMetrics, SandboxStatus, SandboxStopResult, SecurityProfile,
};
use microsandbox::LogLevel;
use microsandbox_network::policy::NetworkPolicy;

use crate::conv;
use crate::error;
use crate::exec::ExecHandle;
use crate::runtime::{block_on, ruby};
use crate::stream::{LogStream, MetricsStream};

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
        if let Some(v) = conv::opt_string(opts, "from_snapshot")? {
            b = b.from_snapshot(v);
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
        // volumes: normalized by the Ruby layer to [guest, kind, source] triples.
        for spec in conv::opt::<Vec<Vec<String>>>(opts, "volumes")?.unwrap_or_default() {
            if spec.len() != 3 {
                return Err(error::base_error("invalid volume mount spec"));
            }
            let (guest, kind, source) = (spec[0].clone(), spec[1].clone(), spec[2].clone());
            match kind.as_str() {
                "bind" | "named" => {}
                other => {
                    return Err(error::base_error(format!(
                        "unknown volume mount kind {other:?} (expected \"bind\" or \"named\")"
                    )))
                }
            }
            b = b.volume(guest, move |m| {
                if kind == "named" {
                    m.named(source)
                } else {
                    m.bind(source)
                }
            });
        }
        if let Some(net) = conv::opt_string(opts, "network")? {
            match net.as_str() {
                "none" | "disabled" | "disable" | "airgapped" => b = b.disable_network(),
                // Default policy is public-only, so no builder call is needed.
                "public" | "public_only" | "default" => {}
                "all" | "allow_all" => b = b.network(|n| n.policy(NetworkPolicy::allow_all())),
                "non_local" | "nonlocal" => b = b.network(|n| n.policy(NetworkPolicy::non_local())),
                other => {
                    return Err(error::base_error(format!(
                        "unknown network mode {other:?} (expected one of \
                         public_only/none/allow_all/non_local)"
                    )))
                }
            }
        }
        if let Some(level) = conv::opt_string(opts, "log_level")? {
            b = b.log_level(log_level_from_str(&level)?);
        }
        if conv::opt_bool(opts, "quiet_logs")? {
            b = b.quiet_logs();
        }
        if let Some(profile) = conv::opt_string(opts, "security")? {
            b = b.security(security_profile_from_str(&profile)?);
        }
        if let Some(policy) = conv::opt_string(opts, "pull_policy")? {
            b = b.pull_policy(pull_policy_from_str(&policy)?);
        }
        if let Some(mib) = conv::opt_u32(opts, "oci_upper_size")? {
            b = b.oci_upper_size(mib);
        }
        if let Some(secs) = conv::opt::<u64>(opts, "max_duration")? {
            b = b.max_duration(secs);
        }
        if let Some(secs) = conv::opt::<u64>(opts, "idle_timeout")? {
            b = b.idle_timeout(secs);
        }
        for (host, guest) in conv::opt_port_map(opts, "ports_udp")? {
            b = b.port_udp(host, guest);
        }
        for (resource, soft, hard) in parse_rlimits(opts)? {
            b = b.rlimit_range(resource, soft, hard);
        }
        // secrets: normalized by the Ruby layer to [env_var, value, allowed_host]
        // triples. Uses the placeholder-based `secret_env` shorthand, which also
        // auto-enables TLS interception (required for value substitution).
        for spec in conv::opt::<Vec<Vec<String>>>(opts, "secrets")?.unwrap_or_default() {
            if spec.len() != 3 {
                return Err(error::base_error(
                    "invalid secret spec (expected [env, value, host])",
                ));
            }
            b = b.secret_env(spec[0].clone(), spec[1].clone(), spec[2].clone());
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

    /// Sandboxes filtered by required `key=value` labels (AND-matched). `opts`
    /// carries a string→string `labels` map.
    fn list_with(opts: RHash) -> Result<RArray, Error> {
        let mut filter = SandboxFilter::new();
        for (k, v) in conv::opt_string_map(opts, "labels")? {
            filter = filter.label(k, v);
        }
        let handles = block_on(microsandbox::Sandbox::list_with(filter)).map_err(error::to_ruby)?;
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

    /// Streaming command execution. Returns an ExecHandle to pull events from.
    fn exec_stream(
        &self,
        cmd: String,
        args: Vec<String>,
        opts: RHash,
    ) -> Result<ExecHandle, Error> {
        let parsed = ExecOpts::parse(args, opts)?;
        let handle = block_on(self.inner.exec_stream_with(cmd, move |b| parsed.apply(b)))
            .map_err(error::to_ruby)?;
        Ok(ExecHandle::from_core(handle))
    }

    /// Streaming shell execution.
    fn shell_stream(&self, script: String, opts: RHash) -> Result<ExecHandle, Error> {
        let parsed = ExecOpts::parse(Vec::new(), opts)?;
        let handle = block_on(
            self.inner
                .shell_stream_with(script, move |b| parsed.apply(b)),
        )
        .map_err(error::to_ruby)?;
        Ok(ExecHandle::from_core(handle))
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

    /// Send the graceful-shutdown request and return without waiting.
    fn request_stop(&self) -> Result<(), Error> {
        block_on(self.inner.request_stop()).map_err(error::to_ruby)
    }

    /// Send the force-kill request and return without waiting.
    fn request_kill(&self) -> Result<(), Error> {
        block_on(self.inner.request_kill()).map_err(error::to_ruby)
    }

    /// Send the drain request and return without waiting.
    fn request_drain(&self) -> Result<(), Error> {
        block_on(self.inner.request_drain()).map_err(error::to_ruby)
    }

    /// Block until the sandbox is observed in a terminal state; returns a
    /// stop-result Hash (name, status, exit_code, signal, observed_at_ms, source).
    fn wait_until_stopped(&self) -> Result<RHash, Error> {
        let result = block_on(self.inner.wait_until_stopped()).map_err(error::to_ruby)?;
        Ok(stop_result_to_hash(&result))
    }

    /// Whether this handle owns the sandbox process lifecycle (a synchronous,
    /// local predicate — no runtime round-trip).
    fn owns_lifecycle(&self) -> bool {
        self.inner.owns_lifecycle()
    }

    /// Disarm the SIGTERM safety net so the sandbox keeps running after this
    /// handle is dropped. The core `detach` consumes the value; the core
    /// `Sandbox` is `Clone` (Arc-backed, sharing the same process handle), so
    /// detaching a clone disarms the shared handle just the same.
    fn detach(&self) -> Result<(), Error> {
        let inner = self.inner.clone();
        block_on(inner.detach());
        Ok(())
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

    /// Stream metrics snapshots at `interval` seconds. Returns a MetricsStream
    /// to pull snapshots from.
    fn metrics_stream(&self, interval: f64) -> MetricsStream {
        let dur = Duration::from_secs_f64(if interval <= 0.0 { 1.0 } else { interval });
        // `metrics_stream` is synchronous but builds a `tokio::time::interval`,
        // which panics ("no reactor running") unless constructed inside the
        // runtime context — so build it under `block_on`. (`log_stream` is async
        // and already runs inside `block_on`, so it needs no such wrapper.)
        let stream = block_on(async { self.inner.metrics_stream(dur) });
        MetricsStream::from_stream(stream)
    }

    /// Stream captured logs as they appear. `opts`: sources, since_ms,
    /// from_cursor, until_ms, follow. Returns a LogStream.
    fn log_stream(&self, opts: RHash) -> Result<LogStream, Error> {
        let log_opts = parse_log_stream_options(opts)?;
        let stream = block_on(self.inner.log_stream(&log_opts)).map_err(error::to_ruby)?;
        Ok(LogStream::from_stream(stream))
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
// Enum / rlimit parsing (string conventions mirror the Python/Go SDKs)
//--------------------------------------------------------------------------------------------------

fn log_level_from_str(s: &str) -> Result<LogLevel, Error> {
    match s {
        "error" => Ok(LogLevel::Error),
        "warn" => Ok(LogLevel::Warn),
        "info" => Ok(LogLevel::Info),
        "debug" => Ok(LogLevel::Debug),
        "trace" => Ok(LogLevel::Trace),
        other => Err(error::base_error(format!(
            "unknown log level {other:?} (expected error/warn/info/debug/trace)"
        ))),
    }
}

fn pull_policy_from_str(s: &str) -> Result<PullPolicy, Error> {
    match s {
        "always" => Ok(PullPolicy::Always),
        "if-missing" | "if_missing" => Ok(PullPolicy::IfMissing),
        "never" => Ok(PullPolicy::Never),
        other => Err(error::base_error(format!(
            "unknown pull policy {other:?} (expected always/if-missing/never)"
        ))),
    }
}

fn security_profile_from_str(s: &str) -> Result<SecurityProfile, Error> {
    match s {
        "default" => Ok(SecurityProfile::Default),
        "restricted" => Ok(SecurityProfile::Restricted),
        other => Err(error::base_error(format!(
            "unknown security profile {other:?} (expected default/restricted)"
        ))),
    }
}

fn rlimit_resource_from_str(s: &str) -> Result<RlimitResource, Error> {
    use RlimitResource::*;
    Ok(match s {
        "cpu" => Cpu,
        "fsize" => Fsize,
        "data" => Data,
        "stack" => Stack,
        "core" => Core,
        "rss" => Rss,
        "nproc" => Nproc,
        "nofile" => Nofile,
        "memlock" => Memlock,
        "as" => As,
        "locks" => Locks,
        "sigpending" => Sigpending,
        "msgqueue" => Msgqueue,
        "nice" => Nice,
        "rtprio" => Rtprio,
        "rttime" => Rttime,
        other => {
            return Err(error::base_error(format!(
                "unknown rlimit resource {other:?}"
            )))
        }
    })
}

/// Parse the `rlimits` option — normalized by the Ruby layer to
/// `[[resource, soft, hard], …]` triples — into core (resource, soft, hard).
fn parse_rlimits(opts: RHash) -> Result<Vec<(RlimitResource, u64, u64)>, Error> {
    let mut out = Vec::new();
    for triple in conv::opt::<Vec<(String, u64, u64)>>(opts, "rlimits")?.unwrap_or_default() {
        out.push((rlimit_resource_from_str(&triple.0)?, triple.1, triple.2));
    }
    Ok(out)
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
    rlimits: Vec<(RlimitResource, u64, u64)>,
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
            rlimits: parse_rlimits(opts)?,
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
        for (resource, soft, hard) in self.rlimits {
            b = b.rlimit_range(resource, soft, hard);
        }
        b
    }
}

//--------------------------------------------------------------------------------------------------
// Value conversions
//--------------------------------------------------------------------------------------------------

/// Collect an iterator of `RHash` into a Ruby `Array`.
fn rhash_array<I: IntoIterator<Item = RHash>>(items: I) -> Result<RArray, Error> {
    let arr = ruby().ary_new();
    for item in items {
        arr.push(item)?;
    }
    Ok(arr)
}

pub(crate) fn exec_output_to_hash(output: microsandbox::ExecOutput) -> Result<RHash, Error> {
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

pub(crate) fn metrics_to_hash(m: &SandboxMetrics) -> RHash {
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

fn stop_result_to_hash(result: &SandboxStopResult) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("name", result.name.clone());
    let _ = hash.aset("status", sandbox_status_str(result.status));
    let _ = hash.aset("exit_code", result.exit_code);
    let _ = hash.aset("signal", result.signal);
    let _ = hash.aset("observed_at_ms", result.observed_at.timestamp_millis());
    let _ = hash.aset("source", result.source.clone());
    hash
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

fn parse_log_stream_options(opts: RHash) -> Result<LogStreamOptions, Error> {
    // `from_cursor` takes precedence over `since_ms` (the two are mutually
    // exclusive in the official SDKs); absent both, start at the beginning.
    let start = if let Some(cursor) = conv::opt_string(opts, "from_cursor")? {
        let parsed: LogCursor = cursor
            .parse()
            .map_err(|_| error::base_error(format!("invalid log cursor {cursor:?}")))?;
        LogStreamStart::From(parsed)
    } else if let Some(since) = conv::opt_f64(opts, "since_ms")?.and_then(ms_to_datetime) {
        LogStreamStart::Since(since)
    } else {
        LogStreamStart::Beginning
    };
    Ok(LogStreamOptions {
        sources: parse_log_sources(opts)?,
        start,
        until: conv::opt_f64(opts, "until_ms")?.and_then(ms_to_datetime),
        follow: conv::opt_bool(opts, "follow")?,
    })
}

pub(crate) fn log_entry_to_hash(entry: &LogEntry) -> RHash {
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
    class.define_singleton_method("list_with", function!(Sandbox::list_with, 1))?;
    class.define_singleton_method("remove", function!(Sandbox::remove, 1))?;

    class.define_method("name", method!(Sandbox::name, 0))?;
    class.define_method("exec", method!(Sandbox::exec, 3))?;
    class.define_method("shell", method!(Sandbox::shell, 2))?;
    class.define_method("exec_stream", method!(Sandbox::exec_stream, 3))?;
    class.define_method("shell_stream", method!(Sandbox::shell_stream, 2))?;
    class.define_method("stop", method!(Sandbox::stop, 1))?;
    class.define_method("kill", method!(Sandbox::kill, 1))?;
    class.define_method("request_stop", method!(Sandbox::request_stop, 0))?;
    class.define_method("request_kill", method!(Sandbox::request_kill, 0))?;
    class.define_method("request_drain", method!(Sandbox::request_drain, 0))?;
    class.define_method(
        "wait_until_stopped",
        method!(Sandbox::wait_until_stopped, 0),
    )?;
    class.define_method("owns_lifecycle", method!(Sandbox::owns_lifecycle, 0))?;
    class.define_method("detach", method!(Sandbox::detach, 0))?;
    class.define_method("metrics", method!(Sandbox::metrics, 0))?;
    class.define_method("metrics_stream", method!(Sandbox::metrics_stream, 1))?;
    class.define_method("logs", method!(Sandbox::logs, 1))?;
    class.define_method("log_stream", method!(Sandbox::log_stream, 1))?;

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
