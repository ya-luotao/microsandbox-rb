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
    AttachOptionsBuilder, FsEntry, FsEntryKind, FsMetadata, Patch, PullPolicy, RlimitResource,
    SandboxFilter, SandboxHandle, SandboxMetrics, SandboxStatus, SandboxStopResult,
    SecurityProfile,
};
use microsandbox::LogLevel;
use microsandbox::RegistryAuth;
use microsandbox_network::policy::{
    Action, Destination, DestinationGroup, Direction, NetworkPolicy, PortRange, Protocol, Rule,
};

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
        // patches: rootfs modifications applied before boot. The Ruby layer
        // normalizes each `Microsandbox::Patch.*` into a string-keyed Hash with
        // a `kind` discriminator; mirrors the Python binding's `apply_patch`.
        for patch in parse_patches(opts)? {
            b = b.add_patch(patch);
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
        // Custom network policy: an ordered allow/deny rule list with per-direction
        // defaults and bulk domain denials. The Ruby layer routes bare presets to
        // the `network` key above and full policies here; mirrors the Python
        // binding's `apply_network`.
        if let Some(policy) = parse_network_policy(opts)? {
            b = b.network(move |n| n.policy(policy));
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
        // Registry connection settings, for private / non-default registries:
        // Basic auth (username + password/token), plain-HTTP `insecure`, and
        // extra PEM CA roots. The Ruby layer flattens `registry_auth: {...}`
        // into these keys; mirrors the Python `registry_auth=` and Node
        // `.registry(r => r.auth(...))` surfaces.
        if let Some(rc) = parse_registry_config(opts)? {
            b = b.registry(move |r| rc.apply(r));
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

    /// A controllable handle for a sandbox by name (running or not). Carries
    /// metadata accessors and the full lifecycle surface (see `SbHandle`).
    fn get(name: String) -> Result<SbHandle, Error> {
        let handle = block_on(microsandbox::Sandbox::get(&name)).map_err(error::to_ruby)?;
        Ok(SbHandle::from_inner(handle))
    }

    /// All sandboxes as controllable handles.
    fn list() -> Result<RArray, Error> {
        let handles = block_on(microsandbox::Sandbox::list()).map_err(error::to_ruby)?;
        let arr = ruby().ary_new();
        for h in handles {
            arr.push(SbHandle::from_inner(h))?;
        }
        Ok(arr)
    }

    /// Sandboxes filtered by required `key=value` labels (AND-matched), as
    /// controllable handles. `opts` carries a string→string `labels` map.
    fn list_with(opts: RHash) -> Result<RArray, Error> {
        let mut filter = SandboxFilter::new();
        for (k, v) in conv::opt_string_map(opts, "labels")? {
            filter = filter.label(k, v);
        }
        let handles = block_on(microsandbox::Sandbox::list_with(filter)).map_err(error::to_ruby)?;
        let arr = ruby().ary_new();
        for h in handles {
            arr.push(SbHandle::from_inner(h))?;
        }
        Ok(arr)
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

    /// Graceful stop. Mirrors the official SDKs: the live handle routes through
    /// a freshly fetched `SandboxHandle::stop` (SIGTERM→SIGKILL escalation with
    /// a 10s default). Fine-grained control — a custom timeout or fire-and-
    /// return `request_*` — lives on `SandboxHandle`, obtained via `Sandbox.get`.
    fn stop(&self) -> Result<(), Error> {
        let name = self.inner.name().to_string();
        block_on(async move {
            let handle = microsandbox::sandbox::Sandbox::get(&name).await?;
            handle.stop().await
        })
        .map_err(error::to_ruby)
    }

    /// Graceful stop, then wait for the process to exit. Returns an exit-status
    /// Hash (`exit_code`, `success`). Local backend only.
    fn stop_and_wait(&self) -> Result<RHash, Error> {
        let status = block_on(self.inner.stop_and_wait()).map_err(error::to_ruby)?;
        Ok(exit_status_to_hash(status))
    }

    /// Force kill (SIGKILL).
    fn kill(&self) -> Result<(), Error> {
        block_on(self.inner.kill()).map_err(error::to_ruby)
    }

    /// Trigger a graceful drain (SIGUSR1 on local).
    fn drain(&self) -> Result<(), Error> {
        block_on(self.inner.drain()).map_err(error::to_ruby)
    }

    /// Wait for the process to exit. Returns an exit-status Hash. Local only.
    fn wait(&self) -> Result<RHash, Error> {
        let status = block_on(self.inner.wait()).map_err(error::to_ruby)?;
        Ok(exit_status_to_hash(status))
    }

    /// Live status fetched from the backend (a round-trip per call).
    fn status(&self) -> Result<String, Error> {
        let status = block_on(self.inner.status()).map_err(error::to_ruby)?;
        Ok(sandbox_status_str(status).to_string())
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

    //----------------------------------------------------------------------
    // SSH (mirror SandboxSshOps)
    //----------------------------------------------------------------------

    /// Open a native in-process SSH client to this sandbox. `opts`: user, term,
    /// sftp (bool, default true).
    fn ssh_open_client(&self, opts: RHash) -> Result<crate::ssh::SshClient, Error> {
        let user = conv::opt_string(opts, "user")?;
        let term = conv::opt_string(opts, "term")?;
        let sftp = conv::opt::<bool>(opts, "sftp")?.unwrap_or(true);
        let ssh = self.inner.ssh();
        let client = block_on(ssh.open_client_with(move |mut b| {
            if let Some(u) = user {
                b = b.user(u);
            }
            if let Some(t) = term {
                b = b.term(t);
            }
            b.sftp(sftp)
        }))
        .map_err(error::to_ruby)?;
        Ok(crate::ssh::SshClient::from_core(client))
    }

    /// Prepare a reusable SSH server endpoint. `opts`: host_key_path,
    /// authorized_keys_path, user, sftp (bool, default true).
    fn ssh_prepare_server(&self, opts: RHash) -> Result<crate::ssh::SshServer, Error> {
        let host_key_path = conv::opt_string(opts, "host_key_path")?;
        let authorized_keys_path = conv::opt_string(opts, "authorized_keys_path")?;
        let user = conv::opt_string(opts, "user")?;
        let sftp = conv::opt::<bool>(opts, "sftp")?.unwrap_or(true);
        let ssh = self.inner.ssh();
        let server = block_on(ssh.prepare_server_with(move |mut b| {
            if let Some(p) = host_key_path {
                b = b.host_key_path(p);
            }
            if let Some(p) = authorized_keys_path {
                b = b.authorized_keys_path(p);
            }
            if let Some(u) = user {
                b = b.user(u);
            }
            b.sftp(sftp)
        }))
        .map_err(error::to_ruby)?;
        Ok(crate::ssh::SshServer::from_core(server))
    }

    //----------------------------------------------------------------------
    // Interactive attach (host-TTY coupled)
    //----------------------------------------------------------------------

    /// Attach an interactive terminal to a command in the sandbox; returns its
    /// exit code. Puts the host terminal in raw mode (requires a real tty) and
    /// blocks until the command exits or the detach sequence is typed. `opts`:
    /// cwd, user, env, detach_keys, rlimits.
    fn attach(&self, cmd: String, args: Vec<String>, opts: RHash) -> Result<i32, Error> {
        let parsed = AttachOpts::parse(args, opts)?;
        block_on(self.inner.attach_with(cmd, move |b| parsed.apply(b))).map_err(error::to_ruby)
    }

    /// Attach an interactive terminal running the sandbox's default shell.
    fn attach_shell(&self) -> Result<i32, Error> {
        block_on(self.inner.attach_shell()).map_err(error::to_ruby)
    }
}

//--------------------------------------------------------------------------------------------------
// Attach option parsing
//--------------------------------------------------------------------------------------------------

struct AttachOpts {
    args: Vec<String>,
    cwd: Option<String>,
    user: Option<String>,
    env: Vec<(String, String)>,
    detach_keys: Option<String>,
    rlimits: Vec<(RlimitResource, u64, u64)>,
}

impl AttachOpts {
    fn parse(args: Vec<String>, opts: RHash) -> Result<Self, Error> {
        Ok(Self {
            args,
            cwd: conv::opt_string(opts, "cwd")?,
            user: conv::opt_string(opts, "user")?,
            env: conv::opt_string_map(opts, "env")?,
            detach_keys: conv::opt_string(opts, "detach_keys")?,
            rlimits: parse_rlimits(opts)?,
        })
    }

    fn apply(self, mut b: AttachOptionsBuilder) -> AttachOptionsBuilder {
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
        if let Some(keys) = self.detach_keys {
            b = b.detach_keys(keys);
        }
        for (resource, soft, hard) in self.rlimits {
            b = b.rlimit_range(resource, soft, hard);
        }
        b
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
// Patch parsing (mirrors the Python binding's `apply_patch`)
//--------------------------------------------------------------------------------------------------

/// Read a required string field from a per-patch Hash.
fn patch_str(h: RHash, key: &str) -> Result<String, Error> {
    conv::opt_string(h, key)?
        .ok_or_else(|| error::base_error(format!("patch is missing required key :{key}")))
}

/// Read a required field as raw bytes (for the binary `file` patch content).
fn patch_bytes(h: RHash, key: &str) -> Result<Vec<u8>, Error> {
    let s = conv::opt::<RString>(h, key)?
        .ok_or_else(|| error::base_error(format!("patch is missing required key :{key}")))?;
    // Copy out while the GVL is held; the buffer is consumed synchronously here.
    Ok(unsafe { s.as_slice() }.to_vec())
}

/// Parse the `patches` option into core `Patch` operations. The Ruby layer
/// normalizes each `Microsandbox::Patch.*` into a string-keyed Hash carrying a
/// `kind` discriminator plus the variant-specific fields.
fn parse_patches(opts: RHash) -> Result<Vec<Patch>, Error> {
    let mut out = Vec::new();
    for h in conv::opt_hash_vec(opts, "patches")? {
        let kind = patch_str(h, "kind")?;
        let mode = conv::opt_u32(h, "mode")?;
        let replace = conv::opt_bool(h, "replace")?;
        let patch = match kind.as_str() {
            "text" => Patch::Text {
                path: patch_str(h, "path")?,
                content: patch_str(h, "content")?,
                mode,
                replace,
            },
            "file" => Patch::File {
                path: patch_str(h, "path")?,
                content: patch_bytes(h, "content")?,
                mode,
                replace,
            },
            "append" => Patch::Append {
                path: patch_str(h, "path")?,
                content: patch_str(h, "content")?,
            },
            "copy_file" => Patch::CopyFile {
                src: patch_str(h, "src")?.into(),
                dst: patch_str(h, "dst")?,
                mode,
                replace,
            },
            "copy_dir" => Patch::CopyDir {
                src: patch_str(h, "src")?.into(),
                dst: patch_str(h, "dst")?,
                replace,
            },
            "symlink" => Patch::Symlink {
                target: patch_str(h, "target")?,
                link: patch_str(h, "link")?,
                replace,
            },
            "mkdir" => Patch::Mkdir {
                path: patch_str(h, "path")?,
                mode,
            },
            "remove" => Patch::Remove {
                path: patch_str(h, "path")?,
            },
            other => {
                return Err(error::base_error(format!(
                    "unknown patch kind {other:?} (expected one of \
                     text/file/append/copy_file/copy_dir/symlink/mkdir/remove)"
                )))
            }
        };
        out.push(patch);
    }
    Ok(out)
}

//--------------------------------------------------------------------------------------------------
// Network policy parsing (mirrors the Python binding's `apply_network`)
//--------------------------------------------------------------------------------------------------

/// Parse the `network_policy` option (a Hash normalized by the Ruby layer) into
/// a core `NetworkPolicy`. Returns `None` when the option is absent (bare
/// presets travel via the separate `network` key handled in `create`).
///
/// Composition (mirrors the Go SDK's `NetworkConfig`): bulk domain-deny rules
/// come first (so they outrank later allow rules), then a preset's rules (if a
/// preset base is given), then the caller's explicit `rules`. Per-direction
/// defaults come from the explicit `default_egress`/`default_ingress` when set,
/// else the preset's defaults, else the asymmetric default (deny egress / allow
/// ingress).
fn parse_network_policy(opts: RHash) -> Result<Option<NetworkPolicy>, Error> {
    let Some(np) = conv::opt::<RHash>(opts, "network_policy")? else {
        return Ok(None);
    };

    // Bulk domain denials → prepended deny-egress rules.
    let mut rules: Vec<Rule> = Vec::new();
    for d in conv::opt_string_vec(np, "deny_domains")? {
        let domain = d
            .parse()
            .map_err(|e| error::base_error(format!("deny_domains {d:?}: {e}")))?;
        rules.push(Rule::deny_egress(Destination::Domain(domain)));
    }
    for s in conv::opt_string_vec(np, "deny_domain_suffixes")? {
        let suffix = s
            .parse()
            .map_err(|e| error::base_error(format!("deny_domain_suffixes {s:?}: {e}")))?;
        rules.push(Rule::deny_egress(Destination::DomainSuffix(suffix)));
    }

    // Optional preset base (its rules and defaults seed the policy).
    let (preset_egress, preset_ingress) = match conv::opt_string(np, "preset")? {
        Some(p) => {
            let mut base = network_preset(&p)?;
            rules.append(&mut base.rules);
            (Some(base.default_egress), Some(base.default_ingress))
        }
        None => (None, None),
    };

    // Caller's explicit rules come after preset rules.
    for rd in conv::opt_hash_vec(np, "rules")? {
        rules.push(parse_rule(rd)?);
    }

    let default_egress = match conv::opt_string(np, "default_egress")? {
        Some(s) => action_from_str(&s)?,
        None => preset_egress.unwrap_or(Action::Deny),
    };
    let default_ingress = match conv::opt_string(np, "default_ingress")? {
        Some(s) => action_from_str(&s)?,
        None => preset_ingress.unwrap_or(Action::Allow),
    };

    Ok(Some(NetworkPolicy {
        default_egress,
        default_ingress,
        rules,
    }))
}

fn network_preset(p: &str) -> Result<NetworkPolicy, Error> {
    Ok(match p {
        "none" | "disabled" | "disable" | "airgapped" => NetworkPolicy::none(),
        "public" | "public_only" | "public-only" | "default" => NetworkPolicy::public_only(),
        "all" | "allow_all" | "allow-all" => NetworkPolicy::allow_all(),
        "non_local" | "non-local" | "nonlocal" => NetworkPolicy::non_local(),
        other => {
            return Err(error::base_error(format!(
                "unknown network preset {other:?} (expected one of \
                 public_only/none/allow_all/non_local)"
            )))
        }
    })
}

fn action_from_str(s: &str) -> Result<Action, Error> {
    match s {
        "allow" => Ok(Action::Allow),
        "deny" => Ok(Action::Deny),
        other => Err(error::base_error(format!(
            "unknown network action {other:?} (expected allow/deny)"
        ))),
    }
}

fn direction_from_str(s: &str) -> Result<Direction, Error> {
    match s {
        "egress" => Ok(Direction::Egress),
        "ingress" => Ok(Direction::Ingress),
        "any" => Ok(Direction::Any),
        other => Err(error::base_error(format!(
            "unknown rule direction {other:?} (expected egress/ingress/any)"
        ))),
    }
}

fn protocol_from_str(s: &str) -> Result<Protocol, Error> {
    match s {
        "tcp" => Ok(Protocol::Tcp),
        "udp" => Ok(Protocol::Udp),
        "icmpv4" => Ok(Protocol::Icmpv4),
        "icmpv6" => Ok(Protocol::Icmpv6),
        other => Err(error::base_error(format!(
            "unknown protocol {other:?} (expected tcp/udp/icmpv4/icmpv6)"
        ))),
    }
}

/// Parse a single rule Hash into a core `Rule`.
fn parse_rule(rd: RHash) -> Result<Rule, Error> {
    let action = action_from_str(&patch_str(rd, "action")?)?;
    let direction = match conv::opt_string(rd, "direction")? {
        Some(s) => direction_from_str(&s)?,
        None => Direction::Egress,
    };
    let kind = conv::opt_string(rd, "destination_kind")?;
    let raw = conv::opt_string(rd, "destination")?;
    let destination = parse_destination(kind.as_deref(), raw.as_deref())?;

    let mut protocols = Vec::new();
    for p in conv::opt_string_vec(rd, "protocols")? {
        let proto = protocol_from_str(&p)?;
        if !protocols.contains(&proto) {
            protocols.push(proto);
        }
    }

    let mut ports = Vec::new();
    for p in conv::opt_string_vec(rd, "ports")? {
        let range = parse_port_range(&p)?;
        if !ports.contains(&range) {
            ports.push(range);
        }
    }

    Ok(Rule {
        direction,
        destination,
        protocols,
        ports,
        action,
    })
}

/// Parse a port string into a `PortRange`. Accepts a single port (`"443"`) or
/// an inclusive range (`"8000-9000"`).
fn parse_port_range(raw: &str) -> Result<PortRange, Error> {
    let invalid = || error::base_error(format!("invalid port {raw:?} (expected N or N-M)"));
    if let Some((lo, hi)) = raw.split_once('-') {
        let lo: u16 = lo.trim().parse().map_err(|_| invalid())?;
        let hi: u16 = hi.trim().parse().map_err(|_| invalid())?;
        if lo > hi {
            return Err(error::base_error(format!(
                "invalid port range {raw:?}: low {lo} exceeds high {hi}"
            )));
        }
        Ok(PortRange::range(lo, hi))
    } else {
        let p: u16 = raw.trim().parse().map_err(|_| invalid())?;
        Ok(PortRange::single(p))
    }
}

/// Resolve a destination from an explicit `kind` + raw value, or — when `kind`
/// is absent — classify the raw shorthand string. Mirrors the Python binding's
/// `parse_network_destination` / `parse_shorthand_destination`.
fn parse_destination(kind: Option<&str>, raw: Option<&str>) -> Result<Destination, Error> {
    let required = |raw: Option<&str>, kind: &str| -> Result<String, Error> {
        raw.map(str::to_string).ok_or_else(|| {
            error::base_error(format!(
                "destination is required for destination kind {kind:?}"
            ))
        })
    };
    match kind {
        Some("any") => Ok(Destination::Any),
        Some("ip") => parse_ip_destination(&required(raw, "ip")?),
        Some("cidr") => parse_cidr_destination(&required(raw, "cidr")?),
        Some("domain") => parse_domain_destination(&required(raw, "domain")?),
        Some("domain_suffix") | Some("domain-suffix") => {
            parse_domain_suffix_destination(&required(raw, "domain_suffix")?)
        }
        Some("group") => parse_group_destination(&required(raw, "group")?),
        Some(other) => Err(error::base_error(format!(
            "unknown destination kind {other:?}"
        ))),
        None => parse_shorthand_destination(raw),
    }
}

fn parse_shorthand_destination(raw: Option<&str>) -> Result<Destination, Error> {
    let Some(raw) = raw else {
        return Ok(Destination::Any);
    };
    if raw == "*" {
        return Ok(Destination::Any);
    }
    if let Some(rest) = raw.strip_prefix("domain=") {
        return parse_domain_destination(rest);
    }
    if let Some(rest) = raw.strip_prefix("suffix=") {
        return parse_domain_suffix_destination(rest);
    }
    if let Some(dest) = maybe_group_destination(raw) {
        return Ok(dest);
    }
    if raw.starts_with('.') {
        return parse_domain_suffix_destination(raw);
    }
    if raw.contains('/') {
        return parse_cidr_destination(raw);
    }
    if raw.parse::<std::net::IpAddr>().is_ok() {
        return parse_ip_destination(raw);
    }
    parse_domain_destination(raw)
}

fn parse_ip_destination(raw: &str) -> Result<Destination, Error> {
    let ip: std::net::IpAddr = raw
        .parse()
        .map_err(|e| error::base_error(format!("invalid IP address {raw:?}: {e}")))?;
    let prefix = if ip.is_ipv4() { 32 } else { 128 };
    let cidr = ipnetwork::IpNetwork::new(ip, prefix)
        .map_err(|e| error::base_error(format!("invalid IP address {raw:?}: {e}")))?;
    Ok(Destination::Cidr(cidr))
}

fn parse_cidr_destination(raw: &str) -> Result<Destination, Error> {
    let cidr: ipnetwork::IpNetwork = raw
        .parse()
        .map_err(|e| error::base_error(format!("invalid CIDR {raw:?}: {e}")))?;
    Ok(Destination::Cidr(cidr))
}

fn parse_domain_destination(raw: &str) -> Result<Destination, Error> {
    let name = raw
        .parse()
        .map_err(|e| error::base_error(format!("invalid domain {raw:?}: {e}")))?;
    Ok(Destination::Domain(name))
}

fn parse_domain_suffix_destination(raw: &str) -> Result<Destination, Error> {
    let name = raw
        .parse()
        .map_err(|e| error::base_error(format!("invalid domain suffix {raw:?}: {e}")))?;
    Ok(Destination::DomainSuffix(name))
}

fn parse_group_destination(raw: &str) -> Result<Destination, Error> {
    maybe_group_destination(raw)
        .ok_or_else(|| error::base_error(format!("unknown destination group {raw:?}")))
}

fn maybe_group_destination(raw: &str) -> Option<Destination> {
    let group = match raw {
        "public" => DestinationGroup::Public,
        "loopback" => DestinationGroup::Loopback,
        "private" => DestinationGroup::Private,
        "link-local" | "link_local" => DestinationGroup::LinkLocal,
        "metadata" => DestinationGroup::Metadata,
        "multicast" => DestinationGroup::Multicast,
        "host" => DestinationGroup::Host,
        _ => return None,
    };
    Some(Destination::Group(group))
}

//--------------------------------------------------------------------------------------------------
// Registry option parsing
//--------------------------------------------------------------------------------------------------

/// Parsed registry connection settings (auth + transport). Built from the flat
/// `registry_*` option keys the Ruby layer normalizes `registry_auth:` into.
struct RegistryConfig {
    auth: Option<RegistryAuth>,
    insecure: bool,
    ca_certs: Vec<String>,
}

impl RegistryConfig {
    fn apply(
        self,
        mut r: microsandbox::sandbox::RegistryConfigBuilder,
    ) -> microsandbox::sandbox::RegistryConfigBuilder {
        if let Some(auth) = self.auth {
            r = r.auth(auth);
        }
        if self.insecure {
            r = r.insecure();
        }
        for pem in self.ca_certs {
            r = r.ca_certs(pem.into_bytes());
        }
        r
    }
}

/// Read the `registry_*` options, returning `None` when none are set (so the
/// default credential-resolution chain in the core is left untouched).
fn parse_registry_config(opts: RHash) -> Result<Option<RegistryConfig>, Error> {
    let username = conv::opt_string(opts, "registry_username")?;
    let password = conv::opt_string(opts, "registry_password")?;
    let insecure = conv::opt_bool(opts, "registry_insecure")?;
    let ca_certs = conv::opt_string_vec(opts, "registry_ca_certs")?;

    let auth = match (username, password) {
        (Some(username), Some(password)) => Some(RegistryAuth::Basic { username, password }),
        (None, None) => None,
        // A half-specified credential is a caller bug, not a silent anonymous pull.
        _ => {
            return Err(error::base_error(
                "registry_auth requires both :username and :password",
            ))
        }
    };

    if auth.is_none() && !insecure && ca_certs.is_empty() {
        return Ok(None);
    }
    Ok(Some(RegistryConfig {
        auth,
        insecure,
        ca_certs,
    }))
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
    stdin_pipe: bool,
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
            stdin_pipe: conv::opt_bool(opts, "stdin_pipe")?,
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
        // Pipe mode opens a writable stdin sink (lifted out by ExecHandle via
        // `take_stdin`); bytes mode feeds a fixed buffer and closes. The core's
        // `StdinMode` is a single enum, so the two are mutually exclusive — pipe
        // wins if a caller somehow sets both.
        if self.stdin_pipe {
            b = b.stdin_pipe();
        } else if let Some(stdin) = self.stdin {
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
    // Lowercased `Debug` names, matching the official SDKs' `format!("{:?}")`.
    // `Created`/`Starting` are new in v0.5.8 (cloud-only today). The match is
    // intentionally exhaustive — no wildcard — so a future upstream variant
    // surfaces as a compile error rather than a silent fallback.
    match status {
        SandboxStatus::Created => "created",
        SandboxStatus::Starting => "starting",
        SandboxStatus::Running => "running",
        SandboxStatus::Draining => "draining",
        SandboxStatus::Paused => "paused",
        SandboxStatus::Stopped => "stopped",
        SandboxStatus::Crashed => "crashed",
    }
}

/// A `std::process::ExitStatus` as a Ruby Hash: `exit_code` (Integer or nil) and
/// `success` (Boolean). Returned by the live `Sandbox#wait` / `#stop_and_wait`.
fn exit_status_to_hash(status: std::process::ExitStatus) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("exit_code", status.code());
    let _ = hash.aset("success", status.success());
    hash
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

//--------------------------------------------------------------------------------------------------
// SandboxHandle — the controllable lightweight handle
//--------------------------------------------------------------------------------------------------

/// Wraps a core `microsandbox::sandbox::SandboxHandle` (returned by
/// `Sandbox.get`/`list`/`list_with`). Carries metadata accessors plus the rich
/// lifecycle surface that moved off the live `Sandbox` in v0.5.8 — mirroring the
/// official Python (`PySandboxHandle`) and Node (`SandboxHandle`) SDKs. Status is
/// a synchronous snapshot read off the handle (no round-trip).
#[magnus::wrap(class = "Microsandbox::Native::SandboxHandle", free_immediately, size)]
pub struct SbHandle {
    inner: SandboxHandle,
}

impl SbHandle {
    fn from_inner(inner: SandboxHandle) -> Self {
        Self { inner }
    }

    fn name(&self) -> String {
        self.inner.name().to_string()
    }

    /// Status snapshot captured when the handle was fetched (synchronous).
    fn status(&self) -> String {
        sandbox_status_str(self.inner.status_snapshot()).to_string()
    }

    fn created_at_ms(&self) -> Option<i64> {
        self.inner.created_at().map(|dt| dt.timestamp_millis())
    }

    fn updated_at_ms(&self) -> Option<i64> {
        self.inner.updated_at().map(|dt| dt.timestamp_millis())
    }

    /// Graceful stop (SIGTERM→SIGKILL escalation, 10s default) and wait.
    fn stop(&self) -> Result<(), Error> {
        block_on(self.inner.stop()).map_err(error::to_ruby)
    }

    /// Graceful stop with a custom escalation timeout (seconds).
    fn stop_with_timeout(&self, secs: f64) -> Result<(), Error> {
        block_on(self.inner.stop_with_timeout(Duration::from_secs_f64(secs)))
            .map_err(error::to_ruby)
    }

    /// Force kill (SIGKILL) and wait.
    fn kill(&self) -> Result<(), Error> {
        block_on(self.inner.kill()).map_err(error::to_ruby)
    }

    /// Force kill, waiting up to `secs` for the process to disappear.
    fn kill_with_timeout(&self, secs: f64) -> Result<(), Error> {
        block_on(self.inner.kill_with_timeout(Duration::from_secs_f64(secs)))
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

    /// Send the drain request (SIGUSR1) and return without waiting.
    fn request_drain(&self) -> Result<(), Error> {
        block_on(self.inner.request_drain()).map_err(error::to_ruby)
    }

    /// Block until the sandbox reaches a terminal state; returns a stop-result
    /// Hash (name, status, exit_code, signal, observed_at_ms, source).
    fn wait_until_stopped(&self) -> Result<RHash, Error> {
        let result = block_on(self.inner.wait_until_stopped()).map_err(error::to_ruby)?;
        Ok(stop_result_to_hash(&result))
    }
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
    class.define_method("stop", method!(Sandbox::stop, 0))?;
    class.define_method("stop_and_wait", method!(Sandbox::stop_and_wait, 0))?;
    class.define_method("kill", method!(Sandbox::kill, 0))?;
    class.define_method("drain", method!(Sandbox::drain, 0))?;
    class.define_method("wait", method!(Sandbox::wait, 0))?;
    class.define_method("status", method!(Sandbox::status, 0))?;
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

    class.define_method("ssh_open_client", method!(Sandbox::ssh_open_client, 1))?;
    class.define_method(
        "ssh_prepare_server",
        method!(Sandbox::ssh_prepare_server, 1),
    )?;

    class.define_method("attach", method!(Sandbox::attach, 3))?;
    class.define_method("attach_shell", method!(Sandbox::attach_shell, 0))?;

    let handle = native.define_class("SandboxHandle", ruby.class_object())?;
    handle.define_method("name", method!(SbHandle::name, 0))?;
    handle.define_method("status", method!(SbHandle::status, 0))?;
    handle.define_method("created_at_ms", method!(SbHandle::created_at_ms, 0))?;
    handle.define_method("updated_at_ms", method!(SbHandle::updated_at_ms, 0))?;
    handle.define_method("stop", method!(SbHandle::stop, 0))?;
    handle.define_method("stop_with_timeout", method!(SbHandle::stop_with_timeout, 1))?;
    handle.define_method("kill", method!(SbHandle::kill, 0))?;
    handle.define_method("kill_with_timeout", method!(SbHandle::kill_with_timeout, 1))?;
    handle.define_method("request_stop", method!(SbHandle::request_stop, 0))?;
    handle.define_method("request_kill", method!(SbHandle::request_kill, 0))?;
    handle.define_method("request_drain", method!(SbHandle::request_drain, 0))?;
    handle.define_method(
        "wait_until_stopped",
        method!(SbHandle::wait_until_stopped, 0),
    )?;

    Ok(())
}
