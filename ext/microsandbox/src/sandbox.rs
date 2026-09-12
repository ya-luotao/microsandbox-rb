//! `Microsandbox::Native::Sandbox` — the single wrapped native class.
//!
//! Holds a core `microsandbox::Sandbox` (cheap to clone; Arc-based) and exposes
//! synchronous, primitive-typed methods. Filesystem operations are folded in as
//! `fs_*` methods rather than a separate wrapper class. Everything that isn't a
//! handle (exec output, metrics, log entries, fs entries/metadata) is returned
//! as a plain Ruby `Hash`/`Array`/`String` and shaped into value objects by the
//! Ruby layer.

use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use magnus::{
    function, method, prelude::*, Error, RArray, RHash, RModule, RString, Ruby, TryConvert, Value,
};
use microsandbox::logs::{
    LogCursor, LogEntry, LogOptions, LogSource, LogStreamOptions, LogStreamStart,
};
use microsandbox::sandbox::{
    AttachOptionsBuilder, DestroyOptions, DiskImageFormat, EnvVar, FlatClone, FsEntry, FsEntryKind,
    FsMetadata, HostPermissions, Patch, PullPolicy, PullProgress, PullProgressHandle,
    RestartOptions, RlimitResource, RootDiskBuilder, SandboxBuilder, SandboxHandle, SandboxMetrics,
    SandboxModificationBuilder, SandboxModificationPatch, SandboxStatus, SandboxStopResult,
    SecretBuilder, SecretModificationPatch, SecretSource, SecurityProfile, StatVirtualization,
};
use microsandbox::LogLevel;
use microsandbox::MicrosandboxResult;
use microsandbox::RegistryAuth;
use microsandbox_network::builder::ViolationActionBuilder;
use microsandbox_network::dns::Nameserver;
use microsandbox_network::policy::{
    Action, Destination, DestinationGroup, Direction, NetworkPolicy, NetworkProfile, PortRange,
    Protocol, Rule,
};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

use crate::conv;
use crate::error;
use crate::exec::ExecHandle;
use crate::runtime::{block_on, ruby};
use crate::stream::{LogStream, MetricsStream};

/// Convert a seconds `f64` into a `Duration`, surfacing a clean Ruby error
/// instead of the panic `Duration::from_secs_f64` raises on NaN/Inf/negative —
/// *and on finite-but-out-of-range* values (e.g. `Float::MAX`). The Ruby
/// `coerce_duration` already guards the public paths, but it sets no upper
/// bound, so a large finite value would still reach (and panic) the native
/// layer; this keeps the native layer panic-free regardless of the Ruby layer,
/// mirroring `agent::dur`.
fn secs_to_duration(secs: f64) -> Result<Duration, Error> {
    Duration::try_from_secs_f64(secs).map_err(|e| {
        error::base_error(format!(
            "duration must be a non-negative, finite number of seconds in range (got {secs}: {e})"
        ))
    })
}

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

    /// Build a configured `SandboxBuilder` from a string-keyed options Hash.
    /// Shared by `create` (blocking) and `create_with_progress` (streaming pull).
    fn build_builder(name: String, opts: RHash) -> Result<SandboxBuilder, Error> {
        let mut b = microsandbox::Sandbox::builder(name);

        if let Some(v) = conv::opt_string(opts, "image")? {
            if let Some(fstype) = conv::opt_string(opts, "fstype")? {
                // An explicit fstype means `image` names a disk-image rootfs path
                // whose inner filesystem can't be auto-probed: route through
                // image_with(disk().fstype()). (A bare `image` string otherwise
                // auto-detects OCI vs disk by extension.) Errors in disk()/fstype()
                // are captured on the builder and surface at create().
                b = b.image_with(move |i| i.disk(v).fstype(fstype));
            } else {
                b = b.image(v);
            }
        }
        if let Some(v) = conv::opt_string(opts, "from_snapshot")? {
            b = b.from_snapshot(v);
        }
        if let Some(v) = conv::opt_u8(opts, "cpus")? {
            b = b.cpus(v);
        }
        // v0.6.6 (#1099): boot-time maximum vCPU / memory ceilings that a later
        // live `modify` can grow up to. `cpus`/`memory` above already raise these
        // to their own value if lower, so a bare `cpus`/`memory` still works;
        // setting these explicitly reserves headroom for a live resize.
        if let Some(v) = conv::opt_u8(opts, "max_cpus")? {
            b = b.max_cpus(v);
        }
        if let Some(v) = conv::opt_u32(opts, "memory")? {
            b = b.memory(v);
        }
        if let Some(v) = conv::opt_u32(opts, "max_memory")? {
            b = b.max_memory(v);
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
        // entrypoint/cmd: presence-keyed, NOT non-emptiness-keyed — an
        // explicitly *empty* array is meaningful for both (it clears the
        // image's ENTRYPOINT / CMD, blocking the image-config merge), exactly
        // like the Python binding. Keying on non-emptiness silently resurrects
        // the image ENTRYPOINT and runs the wrong command under
        // `exec_default`/`attach_default`.
        if let Some(entrypoint) = conv::opt::<Vec<String>>(opts, "entrypoint")? {
            b = b.entrypoint(entrypoint);
        }
        if let Some(cmd) = conv::opt::<Vec<String>>(opts, "cmd")? {
            b = b.cmd(cmd);
        }
        for (host, guest) in conv::opt_port_map(opts, "ports")? {
            b = b.port(host, guest);
        }
        // vsock: host Unix sockets exposed on guest-to-host vsock ports
        // (v0.6.9). Each route is normalized by the Ruby layer to a
        // string-keyed Hash {host_socket:, port:, socket_type: "stream"|"dgram"}.
        for route in conv::opt_hash_vec(opts, "vsock")? {
            let Some(host_socket) = conv::opt_string(route, "host_socket")? else {
                return Err(error::base_error("vsock route requires host_socket:"));
            };
            let Some(port) = conv::opt_u32(route, "port")? else {
                return Err(error::base_error("vsock route requires port:"));
            };
            match conv::opt_string(route, "socket_type")?.as_deref() {
                None | Some("stream") => b = b.vsock(host_socket, port),
                Some("dgram") => b = b.vsock_dgram(host_socket, port),
                Some(other) => {
                    return Err(error::base_error(format!(
                        "unknown vsock socket_type {other:?} (expected stream/dgram)"
                    )))
                }
            }
        }
        // volumes: each mount is normalized by the Ruby layer to a string-keyed
        // Hash — guest (req), kind ("bind"/"named"/"tmpfs"/"disk"), source
        // (bind/named/disk), size_mib (tmpfs/disk), format + fstype (disk),
        // readonly/noexec/nosuid/nodev (bool), stat_virtualization,
        // host_permissions, override_uid/override_gid (u32 pair).
        // Enum-valued options are validated up front (the
        // volume closure can't return an error); the core validates the rest
        // (e.g. rejecting stat_virtualization on tmpfs/disk) at create().
        for m in conv::opt_hash_vec(opts, "volumes")? {
            let guest = conv::opt_string(m, "guest")?
                .ok_or_else(|| error::base_error("volume mount is missing :guest"))?;
            let kind = conv::opt_string(m, "kind")?
                .ok_or_else(|| error::base_error("volume mount is missing :kind"))?;
            let source = conv::opt_string(m, "source")?;
            let size_mib = conv::opt_u32(m, "size_mib")?;
            // Bind-mount guest-write quota override (MiB). The core's MountBuilder
            // applies it to bind mounts only and rejects it on tmpfs/disk/named at
            // build(); we forward it as-is so that validation lives in one place.
            let quota_mib = conv::opt_u32(m, "quota_mib")?;
            let fstype = conv::opt_string(m, "fstype")?;
            let readonly = conv::opt_bool(m, "readonly")?;
            let noexec = conv::opt_bool(m, "noexec")?;
            let nosuid = conv::opt_bool(m, "nosuid")?;
            let nodev = conv::opt_bool(m, "nodev")?;
            let format = conv::opt_string(m, "format")?
                .map(|f| disk_format_from_str(&f))
                .transpose()?;
            let stat_virt = conv::opt_string(m, "stat_virtualization")?
                .map(|s| stat_virtualization_from_str(&s))
                .transpose()?;
            let host_perms = conv::opt_string(m, "host_permissions")?
                .map(|s| host_permissions_from_str(&s))
                .transpose()?;
            // v0.6.15: the fallback guest owner presented for host files that
            // carry no per-file stat override. The Ruby layer validates the pair
            // (both-or-neither, u32 range, bind/named only, not with
            // stat_virtualization=off); whether a *named* volume is directory-
            // or disk-backed is known only to the core, which rejects the
            // disk-backed case at build().
            let override_uid = conv::opt_u32(m, "override_uid")?;
            let override_gid = conv::opt_u32(m, "override_gid")?;
            // v0.6.7: mount-root symlink protection is on by default; this is
            // the per-mount opt-out. Valid for bind/named-directory mounts —
            // the core rejects it elsewhere at build().
            let follow_root_symlinks = conv::opt::<bool>(m, "follow_root_symlinks")?;
            // bind/named/disk require a source; tmpfs must not have one.
            match kind.as_str() {
                "bind" | "named" | "disk" if source.is_some() => {}
                "bind" | "named" | "disk" => {
                    return Err(error::base_error(format!(
                        "volume mount kind {kind:?} requires a source"
                    )))
                }
                "tmpfs" => {}
                other => {
                    return Err(error::base_error(format!(
                        "unknown volume mount kind {other:?} (expected bind/named/tmpfs/disk)"
                    )))
                }
            }
            b = b.volume(guest, move |mut mb| {
                mb = match kind.as_str() {
                    "named" => mb.named(source.unwrap()),
                    "tmpfs" => mb.tmpfs(),
                    "disk" => mb.disk(source.unwrap()),
                    _ => mb.bind(source.unwrap()), // "bind"
                };
                if let Some(n) = size_mib {
                    mb = mb.size(n);
                }
                if let Some(q) = quota_mib {
                    mb = mb.quota(q);
                }
                if let Some(f) = format {
                    mb = mb.format(f);
                }
                if let Some(ft) = fstype {
                    mb = mb.fstype(ft);
                }
                if readonly {
                    mb = mb.readonly();
                }
                if noexec {
                    mb = mb.noexec();
                }
                if nosuid {
                    mb = mb.nosuid();
                }
                if nodev {
                    mb = mb.nodev();
                }
                if let Some(sv) = stat_virt {
                    mb = mb.stat_virtualization(sv);
                }
                if let Some(hp) = host_perms {
                    mb = mb.host_permissions(hp);
                }
                if let (Some(uid), Some(gid)) = (override_uid, override_gid) {
                    mb = mb.owner(uid, gid);
                }
                if let Some(follow) = follow_root_symlinks {
                    mb = mb.follow_root_symlinks(follow);
                }
                mb
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
                "all" | "allow_all" => b = b.network(|n| n.policy(NetworkPolicy::allow_all())),
                other => {
                    return Err(error::base_error(format!(
                        "unknown network mode {other:?} (expected none/allow_all; compose \
                         public/private/host access via network profiles)"
                    )))
                }
            }
        }
        // Composable network profiles (v0.6.7): expanded to the canonical rule
        // set plus a gateway-DNS allow by the core's
        // `NetworkPolicy::from_profiles`. The Ruby layer routes
        // `network: [:public, :host]` (and single-profile sugar) here. An empty
        // profile set never reaches this key — the Ruby layer sends it as an
        // explicit empty custom policy, which has identical semantics.
        let profile_names = conv::opt_string_vec(opts, "network_profiles")?;
        if !profile_names.is_empty() {
            let profiles = profile_names
                .iter()
                .map(|s| network_profile_from_str(s))
                .collect::<Result<Vec<_>, Error>>()?;
            b = b.network(move |n| n.policy(NetworkPolicy::from_profiles(profiles)));
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
        // Writable root-disk spec for OCI sandboxes (v0.6.7): Integer = managed
        // ext4 upper size in MiB (the pre-0.6.7 `oci_upper_size` meaning), Hash =
        // {kind: managed|tmpfs|disk, size_mib, path, format, fstype}. The Ruby
        // layer maps the deprecated `oci_upper_size:` kwarg to the managed kind
        // before it reaches the wire.
        if let Some(v) = conv::opt::<Value>(opts, "root_disk")? {
            let spec = parse_root_disk(v)?;
            b = b.root_disk_with(move |d| spec.apply(d));
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
        // secrets: each entry is normalized by the Ruby layer to a string-keyed
        // Hash — env (req), value (req), hosts / host_patterns (allow lists),
        // placeholder, require_tls, inject_{headers,basic_auth,query,body},
        // on_violation. Routed through the full secret builder (`b.secret`), which
        // auto-enables TLS interception. Mirrors the Python/Node SecretEntry.
        for h in conv::opt_hash_vec(opts, "secrets")? {
            let spec = parse_secret(h)?;
            b = b.secret(move |s| spec.apply(s));
        }
        // Sandbox-level secret-leak policy (block / block_and_log /
        // block_and_terminate / passthrough). Applied via the network builder,
        // which accumulates on top of any policy/dns/tls already configured.
        if let Some(v) = conv::opt::<Value>(opts, "on_secret_violation")? {
            let spec = parse_violation_spec(v)?;
            b = b.network(move |n| n.on_secret_violation(move |va| spec.apply(va)));
        }
        // Advanced network configuration (custom DNS, TLS-interception tuning,
        // guest IP pools, connection cap, host-CA trust), applied via the network
        // builder, which accumulates on top of any policy already configured.
        // Mirrors the Python binding's `apply_network`. Parsed up front because
        // the builder closures cannot return an error.
        let dns = conv::opt::<RHash>(opts, "dns")?
            .map(parse_dns)
            .transpose()?;
        let tls = conv::opt::<RHash>(opts, "tls")?
            .map(parse_tls)
            .transpose()?;
        let ipv4_pool = conv::opt_string(opts, "ipv4_pool")?
            .map(|s| {
                s.parse::<ipnetwork::Ipv4Network>()
                    .map_err(|e| error::base_error(format!("invalid ipv4_pool {s:?}: {e}")))
            })
            .transpose()?;
        let ipv6_pool = conv::opt_string(opts, "ipv6_pool")?
            .map(|s| {
                s.parse::<ipnetwork::Ipv6Network>()
                    .map_err(|e| error::base_error(format!("invalid ipv6_pool {s:?}: {e}")))
            })
            .transpose()?;
        let max_connections = conv::opt::<usize>(opts, "max_connections")?;
        let trust_host_cas = conv::opt::<bool>(opts, "trust_host_cas")?;
        // strict: fail-closed hostname-policy enforcement (v0.6.18). A
        // hostname-rule allow must be backed by an inspectable request
        // authority (plain-HTTP Host, or SNI/authority under TLS interception);
        // otherwise the flow is denied before the upstream dial. Mirrors the
        // Python SDK's `Network(strict=...)`. Create-only here to match the
        // Python SDK's `modify` surface, which does not expose `strict`; the
        // core's generated network config patch (ConfigPatch derive) does
        // carry a `strict` field, so this is SDK parity, not a core limit.
        let strict = conv::opt::<bool>(opts, "strict")?;
        if dns.is_some()
            || tls.is_some()
            || ipv4_pool.is_some()
            || ipv6_pool.is_some()
            || max_connections.is_some()
            || trust_host_cas.is_some()
            || strict.is_some()
        {
            b = b.network(move |mut n| {
                if let Some(dns) = dns {
                    n = n.dns(move |mut d| {
                        if !dns.nameservers.is_empty() {
                            d = d.nameservers(dns.nameservers);
                        }
                        if let Some(rp) = dns.rebind_protection {
                            d = d.rebind_protection(rp);
                        }
                        if let Some(qt) = dns.query_timeout_ms {
                            d = d.query_timeout_ms(qt);
                        }
                        d
                    });
                }
                if let Some(tls) = tls {
                    n = n.tls(move |mut t| {
                        for pat in tls.bypass {
                            t = t.bypass(pat);
                        }
                        if let Some(v) = tls.verify_upstream {
                            t = t.verify_upstream(v);
                        }
                        if let Some(ports) = tls.intercepted_ports {
                            t = t.intercepted_ports(ports);
                        }
                        if let Some(q) = tls.block_quic {
                            t = t.block_quic(q);
                        }
                        if let Some(p) = tls.upstream_ca_cert {
                            t = t.upstream_ca_cert(p);
                        }
                        if let Some(p) = tls.intercept_ca_cert {
                            t = t.intercept_ca_cert(p);
                        }
                        if let Some(p) = tls.intercept_ca_key {
                            t = t.intercept_ca_key(p);
                        }
                        t
                    });
                }
                if let Some(p) = ipv4_pool {
                    n = n.ipv4_pool(p);
                }
                if let Some(p) = ipv6_pool {
                    n = n.ipv6_pool(p);
                }
                if let Some(m) = max_connections {
                    n = n.max_connections(m);
                }
                if let Some(t) = trust_host_cas {
                    n = n.trust_host_cas(t);
                }
                if let Some(s) = strict {
                    n = n.strict(s);
                }
                n
            });
        }
        // rate_limiter: per-sandbox egress/ingress token-bucket limits
        // (v0.6.9). The Ruby layer normalizes the option to a string-keyed
        // Hash {egress:, ingress:} of {bandwidth:, ops:} buckets
        // {size:, refill_time_ms:, one_time_burst:}; mirrors the Python SDK's
        // `NetworkRateLimiter`. Applied via the network builder, accumulating
        // on top of any configuration above.
        if let Some(spec) = conv::opt::<RHash>(opts, "rate_limiter")?
            .map(parse_rate_limiter)
            .transpose()?
        {
            b = b.network(move |n| {
                n.rate_limiter(move |mut r| {
                    if let Some(egress) = spec.egress {
                        r = r.egress(move |rl| egress.apply(rl));
                    }
                    if let Some(ingress) = spec.ingress {
                        r = r.ingress(move |rl| ingress.apply(rl));
                    }
                    r
                })
            });
        }
        // proxy: outbound SOCKS4/SOCKS5 proxy for egress traffic (v0.6.17,
        // upstream #1234/#1507). The Ruby layer (`OutboundProxy.coerce`) has
        // already validated the shape and normalized it to the Python SDK's
        // `_to_dict()` wire form: {protocol:, address:, user_id?:,
        // credentials?: {username:, password: {kind: "env", var:}}}. Only the
        // password's env var NAME travels; the core resolves it host-side.
        // Applied exactly as sdk/python/src/helpers.rs does; the address is
        // parsed by the core's proxy builder (an invalid one surfaces as
        // NetworkBuilder(InvalidOutboundProxy) → InvalidConfigError, see error.rs).
        if let Some(proxy) = conv::opt::<RHash>(opts, "proxy")? {
            b = apply_outbound_proxy(b, proxy)?;
        }
        // init: hand guest PID 1 to an init system. The Ruby layer normalizes
        // `init:` to a Hash { cmd:, args?:, env?: }. `init_with` with empty
        // args/env builds the same HandoffInit as the plain `init(cmd)`, so route
        // everything through the one closure-builder.
        if let Some(h) = conv::opt::<RHash>(opts, "init")? {
            let cmd = conv::opt_string(h, "cmd")?
                .ok_or_else(|| error::base_error("init requires a :cmd"))?;
            let args = conv::opt_string_vec(h, "args")?;
            let env = conv::opt_string_map(h, "env")?;
            b = b.init_with(cmd, move |i| i.args(args).envs(env));
        }
        if conv::opt_bool(opts, "ephemeral")? {
            b = b.ephemeral(true);
        }
        if conv::opt_bool(opts, "detached")? {
            b = b.detached(true);
        }
        if let Some(secs) = conv::opt_f64(opts, "replace_with_timeout")? {
            b = b.replace_with_timeout(secs_to_duration(secs)?);
        } else if conv::opt_bool(opts, "replace")? {
            b = b.replace();
        }

        Ok(b)
    }

    /// Create and boot a sandbox. `opts` is a string-keyed options Hash.
    fn create(name: String, opts: RHash) -> Result<Sandbox, Error> {
        let b = Self::build_builder(name, opts)?;
        let inner = block_on(b.create()).map_err(error::to_ruby)?;
        Ok(Sandbox::from_inner(inner))
    }

    /// Create a sandbox with streaming image-pull progress. Returns a
    /// `PullSession` whose `recv` yields progress events and whose `result`
    /// resolves to the booted sandbox. Mirrors Python `create_with_progress` /
    /// Node `createWithPullProgress`.
    fn create_with_progress(name: String, opts: RHash) -> Result<PullSession, Error> {
        let b = Self::build_builder(name, opts)?;
        // `create_with_pull_progress` spawns a tokio task, so it must run inside
        // the runtime context even though the call itself is synchronous.
        let (handle, join) =
            block_on(async move { b.create_with_pull_progress() }).map_err(error::to_ruby)?;
        Ok(PullSession::new(handle, join))
    }

    /// Converge on a live sandbox with this name: connect to (or start) the
    /// persisted one when it already exists, otherwise create it from `opts`.
    /// Concurrent callers converge on the winning identity. The core rejects
    /// the combination with `replace`.
    fn connect_or_create(name: String, opts: RHash) -> Result<Sandbox, Error> {
        let b = Self::build_builder(name, opts)?;
        let inner = block_on(b.connect_or_create()).map_err(error::to_ruby)?;
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

    /// Convert one `SandboxPage` into a `{ "sandboxes" => [SbHandle], "next_cursor" => String|nil }`
    /// Ruby Hash (v0.6.8 paginated listing contract).
    fn page_to_hash(page: microsandbox::sandbox::SandboxPage) -> Result<RHash, Error> {
        let arr = ruby().ary_new();
        for h in page.sandboxes {
            arr.push(SbHandle::from_inner(h))?;
        }
        let hash = ruby().hash_new();
        hash.aset("sandboxes", arr)?;
        hash.aset("next_cursor", page.next_cursor)?;
        Ok(hash)
    }

    /// First page of sandboxes (default page size), as a page Hash of
    /// controllable handles.
    fn list() -> Result<RHash, Error> {
        let page = block_on(microsandbox::Sandbox::list()).map_err(error::to_ruby)?;
        Self::page_to_hash(page)
    }

    /// One configured page of sandboxes as a page Hash. `opts` carries an
    /// optional string→string `labels` map (AND-matched), an optional `limit`
    /// (1..=100) and an optional opaque `cursor` from a previous page.
    fn list_with(opts: RHash) -> Result<RHash, Error> {
        let labels = conv::opt_string_map(opts, "labels")?;
        let limit = conv::opt_u32(opts, "limit")?;
        let cursor = conv::opt_string(opts, "cursor")?;
        let page = block_on(microsandbox::Sandbox::list_with(move |mut b| {
            if let Some(limit) = limit {
                b = b.limit(limit);
            }
            if let Some(cursor) = cursor {
                b = b.cursor(cursor);
            }
            b.labels(labels)
        }))
        .map_err(error::to_ruby)?;
        Self::page_to_hash(page)
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

    /// The opaque, backend-assigned identity of this persisted sandbox
    /// (v0.6.16). Stable for the sandbox's lifetime, and different once the
    /// same name is removed and recreated.
    fn id(&self) -> String {
        self.inner.id().to_string()
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

    /// Run the image's resolved OCI ENTRYPOINT and CMD (the default workload,
    /// v0.6.9) and wait for completion. `create` is strictly boot-only, so this
    /// is how the image's own command is executed. `opts` matches `exec` minus
    /// the command: cwd, user, env, timeout, tty, stdin, rlimits. Raises
    /// NoDefaultCommandError when the image resolves no executable command.
    fn exec_default(&self, opts: RHash) -> Result<RHash, Error> {
        let parsed = ExecOpts::parse(Vec::new(), opts)?;
        let output = block_on(self.inner.exec_default_with(move |b| parsed.apply(b)))
            .map_err(error::to_ruby)?;
        exec_output_to_hash(output)
    }

    /// Streaming default-workload execution. Returns an ExecHandle.
    fn exec_default_stream(&self, opts: RHash) -> Result<ExecHandle, Error> {
        let parsed = ExecOpts::parse(Vec::new(), opts)?;
        let handle = block_on(
            self.inner
                .exec_default_stream_with(move |b| parsed.apply(b)),
        )
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

    /// Graceful stop (SIGTERM→SIGKILL escalation with a 10s default), routed
    /// straight through the live sandbox like every other lifecycle method here
    /// and like both official bindings (`sdk/python/src/sandbox.rs`,
    /// `sdk/ruby/ext/.../lib.rs`).
    ///
    /// This deliberately does NOT re-fetch a `SandboxHandle` by name first. It
    /// used to, back when the core's live `stop` was not identity-scoped; as of
    /// v0.6.16 the core routes `stop` → `request_stop` → `stop_identified(name,
    /// self.identity())`, so going through `self.inner` is what makes the stop
    /// refuse a same-name replacement (`SandboxReplacedError`) instead of
    /// terminating whatever sandbox happens to own the name right now. The old
    /// by-name refetch threw that identity away.
    ///
    /// Fine-grained control — a custom timeout or fire-and-return `request_*` —
    /// lives on `SandboxHandle`, obtained via `Sandbox.get`.
    fn stop(&self) -> Result<(), Error> {
        block_on(self.inner.stop()).map_err(error::to_ruby)
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

    /// Block until this exact sandbox reaches `status` (no built-in timeout),
    /// returning a fresh handle. A same-name replacement raises
    /// `SandboxReplacedError` instead of silently redirecting the wait.
    fn wait_for_status(&self, status: String) -> Result<SbHandle, Error> {
        let status = sandbox_status_from_str(&status)?;
        let handle = block_on(self.inner.wait_for_status(status)).map_err(error::to_ruby)?;
        Ok(SbHandle::from_inner(handle))
    }

    /// Stop and start this exact sandbox, returning the new live sandbox.
    /// `opts` carries `force`/`timeout`/`detached`.
    fn restart(&self, opts: RHash) -> Result<Sandbox, Error> {
        let options = restart_options(opts)?;
        let inner = block_on(self.inner.restart_with(options)).map_err(error::to_ruby)?;
        Ok(Sandbox::from_inner(inner))
    }

    /// Stop and remove this exact sandbox. `opts` carries `force`/`timeout`.
    fn destroy(&self, opts: RHash) -> Result<(), Error> {
        let options = destroy_options(opts)?;
        block_on(self.inner.destroy_with(options)).map_err(error::to_ruby)
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

    //----------------------------------------------------------------------
    // Health & modification (v0.6.6 / #1099)
    //----------------------------------------------------------------------

    /// Health-check the guest agent without refreshing the idle timer. Returns
    /// `{ name, latency_secs }` (round-trip latency as f64 seconds; the Ruby
    /// layer exposes both seconds and milliseconds).
    fn ping(&self) -> Result<RHash, Error> {
        let result = block_on(self.inner.ping()).map_err(error::to_ruby)?;
        Ok(ping_result_to_hash(&result))
    }

    /// Explicitly refresh the idle-activity timer. Returns
    /// `{ name, activity_seq }`.
    fn touch(&self) -> Result<RHash, Error> {
        let result = block_on(self.inner.touch()).map_err(error::to_ruby)?;
        Ok(touch_result_to_hash(&result))
    }

    /// Plan or apply a live sandbox modification. `opts` is the string-keyed
    /// modify Hash normalized by the Ruby layer; returns the resulting
    /// `SandboxModificationPlan` as a JSON string, which the Ruby layer parses
    /// into a `ModificationPlan`. Mirrors the Node native binding (native returns
    /// JSON, the wrapper shapes it).
    fn modify(&self, opts: RHash) -> Result<String, Error> {
        run_modify(self.inner.modify(), opts)
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
    fn metrics_stream(&self, interval: f64) -> Result<MetricsStream, Error> {
        // `interval <= 0.0` (0 or negative) keeps the prior 1s-default behavior;
        // NaN (for which `<= 0.0` is false) and finite-but-out-of-range values
        // fall through to `secs_to_duration`, which errors cleanly rather than
        // letting `from_secs_f64` panic across the FFI boundary.
        let dur = if interval <= 0.0 {
            Duration::from_secs(1)
        } else {
            secs_to_duration(interval)?
        };
        // `metrics_stream` is synchronous but builds a `tokio::time::interval`,
        // which panics ("no reactor running") unless constructed inside the
        // runtime context — so build it under `block_on`. (`log_stream` is async
        // and already runs inside `block_on`, so it needs no such wrapper.)
        let stream = block_on(async { self.inner.metrics_stream(dur) });
        Ok(MetricsStream::from_stream(stream))
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

    /// Open a streaming reader over a guest file (for files too large to buffer).
    fn fs_read_stream(&self, path: String) -> Result<crate::fs_stream::FsReadStreamHandle, Error> {
        let fs = self.inner.fs();
        let stream = block_on(fs.read_stream(&path)).map_err(error::to_ruby)?;
        Ok(crate::fs_stream::FsReadStreamHandle::new(stream))
    }

    /// Open a streaming writer to a guest file.
    fn fs_write_stream(&self, path: String) -> Result<crate::fs_stream::FsWriteSinkHandle, Error> {
        let fs = self.inner.fs();
        let sink = block_on(fs.write_stream(&path)).map_err(error::to_ruby)?;
        Ok(crate::fs_stream::FsWriteSinkHandle::new(sink))
    }

    //----------------------------------------------------------------------
    // SSH (mirror SandboxSshOps)
    //----------------------------------------------------------------------

    /// Open a native in-process SSH client to this sandbox. `opts`: user, term,
    /// sftp (bool, default true), inactivity_timeout (seconds, f64; 0 disables).
    fn ssh_open_client(&self, opts: RHash) -> Result<crate::ssh::SshClient, Error> {
        let user = conv::opt_string(opts, "user")?;
        let term = conv::opt_string(opts, "term")?;
        let sftp = conv::opt::<bool>(opts, "sftp")?.unwrap_or(true);
        let inactivity_timeout = conv::opt_f64(opts, "inactivity_timeout")?
            .map(secs_to_duration)
            .transpose()?;
        let ssh = self.inner.ssh();
        let client = block_on(ssh.open_client_with(move |mut b| {
            if let Some(u) = user {
                b = b.user(u);
            }
            if let Some(t) = term {
                b = b.term(t);
            }
            if let Some(t) = inactivity_timeout {
                b = b.inactivity_timeout(t);
            }
            b.sftp(sftp)
        }))
        .map_err(error::to_ruby)?;
        Ok(crate::ssh::SshClient::from_core(client))
    }

    /// Prepare a reusable SSH server endpoint. `opts`: host_key_path,
    /// authorized_keys_path, user, sftp (bool, default true),
    /// inactivity_timeout (seconds, f64; 0 disables).
    fn ssh_prepare_server(&self, opts: RHash) -> Result<crate::ssh::SshServer, Error> {
        let host_key_path = conv::opt_string(opts, "host_key_path")?;
        let authorized_keys_path = conv::opt_string(opts, "authorized_keys_path")?;
        let user = conv::opt_string(opts, "user")?;
        let sftp = conv::opt::<bool>(opts, "sftp")?.unwrap_or(true);
        let inactivity_timeout = conv::opt_f64(opts, "inactivity_timeout")?
            .map(secs_to_duration)
            .transpose()?;
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
            if let Some(t) = inactivity_timeout {
                b = b.inactivity_timeout(t);
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

    /// Attach an interactive terminal to the image's resolved OCI ENTRYPOINT
    /// and CMD (the default workload, v0.6.9); returns its exit code. `opts`:
    /// cwd, user, env, detach_keys, rlimits.
    fn attach_default(&self, opts: RHash) -> Result<i32, Error> {
        let parsed = AttachOpts::parse(Vec::new(), opts)?;
        block_on(self.inner.attach_default_with(move |b| parsed.apply(b))).map_err(error::to_ruby)
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
// Mount enum parsing
//--------------------------------------------------------------------------------------------------

fn disk_format_from_str(s: &str) -> Result<DiskImageFormat, Error> {
    // Delegate the qcow2/raw/vmdk mapping to the core's `FromStr` (single source
    // of truth) but keep the friendlier, option-listing error message.
    s.parse::<DiskImageFormat>().map_err(|_| {
        error::base_error(format!(
            "unknown disk format {s:?} (expected qcow2/raw/vmdk)"
        ))
    })
}

fn stat_virtualization_from_str(s: &str) -> Result<StatVirtualization, Error> {
    use StatVirtualization::*;
    Ok(match s {
        "strict" => Strict,
        "relaxed" => Relaxed,
        "off" => Off,
        other => {
            return Err(error::base_error(format!(
                "unknown stat_virtualization {other:?} (expected strict/relaxed/off)"
            )))
        }
    })
}

fn host_permissions_from_str(s: &str) -> Result<HostPermissions, Error> {
    use HostPermissions::*;
    Ok(match s {
        "private" => Private,
        "mirror" => Mirror,
        other => {
            return Err(error::base_error(format!(
                "unknown host_permissions {other:?} (expected private/mirror)"
            )))
        }
    })
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
// Secret parsing (mirrors the Python/Node SecretEntry surface)
//--------------------------------------------------------------------------------------------------

/// A secret-leak response. Per-secret (`on_violation:`) and sandbox-level
/// (`on_secret_violation:`) share the same shape.
enum ViolationSpec {
    Block,
    BlockAndLog,
    BlockAndTerminate,
    Passthrough {
        hosts: Vec<String>,
        patterns: Vec<String>,
        all: bool,
    },
}

impl ViolationSpec {
    fn apply(self, mut v: ViolationActionBuilder) -> ViolationActionBuilder {
        match self {
            ViolationSpec::Block => v.block(),
            ViolationSpec::BlockAndLog => v.block_and_log(),
            ViolationSpec::BlockAndTerminate => v.block_and_terminate(),
            ViolationSpec::Passthrough {
                hosts,
                patterns,
                all,
            } => {
                for h in hosts {
                    v = v.passthrough_host(h);
                }
                for p in patterns {
                    v = v.passthrough_host_pattern(p);
                }
                if all {
                    v = v.passthrough_all_hosts(true);
                }
                v
            }
        }
    }
}

/// Parse `on_violation:` — a String (block variants) or a Hash describing a
/// passthrough action — into a [`ViolationSpec`].
fn parse_violation_spec(v: Value) -> Result<ViolationSpec, Error> {
    if let Ok(s) = String::try_convert(v) {
        return match s.as_str() {
            "block" => Ok(ViolationSpec::Block),
            "block_and_log" => Ok(ViolationSpec::BlockAndLog),
            "block_and_terminate" => Ok(ViolationSpec::BlockAndTerminate),
            other => Err(error::base_error(format!(
                "unknown on_violation {other:?} (expected block/block_and_log/\
                 block_and_terminate, or a Hash with :passthrough_hosts/\
                 :passthrough_host_patterns/:passthrough_all_hosts)"
            ))),
        };
    }
    let h = RHash::try_convert(v)
        .map_err(|_| error::base_error("on_violation must be a String or a Hash"))?;
    Ok(ViolationSpec::Passthrough {
        hosts: conv::opt_string_vec(h, "passthrough_hosts")?,
        patterns: conv::opt_string_vec(h, "passthrough_host_patterns")?,
        all: conv::opt_bool(h, "passthrough_all_hosts")?,
    })
}

struct SecretSpec {
    env: String,
    value: String,
    hosts: Vec<String>,
    host_patterns: Vec<String>,
    placeholder: Option<String>,
    require_tls: Option<bool>,
    inject_headers: Option<bool>,
    inject_basic_auth: Option<bool>,
    inject_query: Option<bool>,
    inject_body: Option<bool>,
    on_violation: Option<ViolationSpec>,
}

fn parse_secret(h: RHash) -> Result<SecretSpec, Error> {
    let env =
        conv::opt_string(h, "env")?.ok_or_else(|| error::base_error("secret requires :env"))?;
    let value =
        conv::opt_string(h, "value")?.ok_or_else(|| error::base_error("secret requires :value"))?;
    let hosts = conv::opt_string_vec(h, "hosts")?;
    let host_patterns = conv::opt_string_vec(h, "host_patterns")?;
    if hosts.is_empty() && host_patterns.is_empty() {
        return Err(error::base_error(
            "secret requires at least one allowed host (:host, :hosts, or :host_patterns)",
        ));
    }
    let on_violation = conv::opt::<Value>(h, "on_violation")?
        .map(parse_violation_spec)
        .transpose()?;
    Ok(SecretSpec {
        env,
        value,
        hosts,
        host_patterns,
        placeholder: conv::opt_string(h, "placeholder")?,
        require_tls: conv::opt::<bool>(h, "require_tls")?,
        inject_headers: conv::opt::<bool>(h, "inject_headers")?,
        inject_basic_auth: conv::opt::<bool>(h, "inject_basic_auth")?,
        inject_query: conv::opt::<bool>(h, "inject_query")?,
        inject_body: conv::opt::<bool>(h, "inject_body")?,
        on_violation,
    })
}

impl SecretSpec {
    fn apply(self, mut s: SecretBuilder) -> SecretBuilder {
        s = s.env(self.env).value(self.value);
        for host in self.hosts {
            s = s.allow_host(host);
        }
        for pat in self.host_patterns {
            s = s.allow_host_pattern(pat);
        }
        if let Some(p) = self.placeholder {
            s = s.placeholder(p);
        }
        if let Some(rt) = self.require_tls {
            s = s.require_tls_identity(rt);
        }
        if let Some(enabled) = self.inject_headers {
            s = s.inject_headers(enabled);
        }
        if let Some(enabled) = self.inject_basic_auth {
            s = s.inject_basic_auth(enabled);
        }
        if let Some(enabled) = self.inject_query {
            s = s.inject_query(enabled);
        }
        if let Some(enabled) = self.inject_body {
            s = s.inject_body(enabled);
        }
        if let Some(action) = self.on_violation {
            s = s.on_violation(move |v| action.apply(v));
        }
        s
    }
}

//--------------------------------------------------------------------------------------------------
// Network connection config parsing (DNS / TLS interception)
//--------------------------------------------------------------------------------------------------

struct DnsSpec {
    nameservers: Vec<Nameserver>,
    rebind_protection: Option<bool>,
    query_timeout_ms: Option<u64>,
}

fn parse_dns(d: RHash) -> Result<DnsSpec, Error> {
    let mut nameservers = Vec::new();
    for s in conv::opt_string_vec(d, "nameservers")? {
        nameservers.push(
            s.parse::<Nameserver>()
                .map_err(|e| error::base_error(format!("invalid nameserver {s:?}: {e}")))?,
        );
    }
    Ok(DnsSpec {
        nameservers,
        rebind_protection: conv::opt::<bool>(d, "rebind_protection")?,
        query_timeout_ms: conv::opt::<u64>(d, "query_timeout_ms")?,
    })
}

/// Apply the normalized `proxy` create option (v0.6.17) to the builder.
/// Mirrors `sdk/python/src/helpers.rs`: `socks4` takes an optional `user_id`,
/// `socks5` optional `credentials` whose password is an env-backed
/// [`SecretSource`] (the only kind). Unknown protocols and non-env password
/// sources are rejected here (the Ruby layer already does, so these are
/// belt-and-braces for callers of the native API).
fn apply_outbound_proxy(b: SandboxBuilder, proxy: RHash) -> Result<SandboxBuilder, Error> {
    let protocol = conv::opt_string(proxy, "protocol")?
        .ok_or_else(|| error::base_error("proxy requires protocol:"))?;
    let address = conv::opt_string(proxy, "address")?
        .ok_or_else(|| error::base_error("proxy requires address:"))?;
    match protocol.as_str() {
        "socks4" => {
            let user_id = conv::opt_string(proxy, "user_id")?;
            Ok(b.proxy(move |p| {
                let p = p.socks4(address);
                match user_id {
                    Some(user_id) => p.user_id(user_id),
                    None => p,
                }
            }))
        }
        "socks5" => {
            let credentials = match conv::opt::<RHash>(proxy, "credentials")? {
                None => None,
                Some(c) => {
                    let username = conv::opt_string(c, "username")?
                        .ok_or_else(|| error::base_error("SOCKS5 credentials require username:"))?;
                    let password = conv::opt::<RHash>(c, "password")?
                        .ok_or_else(|| error::base_error("SOCKS5 credentials require password:"))?;
                    let kind = conv::opt_string(password, "kind")?.ok_or_else(|| {
                        error::base_error("SOCKS5 password source requires kind:")
                    })?;
                    if kind != "env" {
                        return Err(error::base_error(format!(
                            "unsupported SOCKS5 password source {kind:?}; only env is supported"
                        )));
                    }
                    let var = conv::opt_string(password, "var")?
                        .ok_or_else(|| error::base_error("SOCKS5 password source requires var:"))?;
                    Some((username, SecretSource::env(var)))
                }
            };
            Ok(b.proxy(move |p| {
                let p = p.socks5(address);
                match credentials {
                    Some((username, password)) => p.credentials(username, password),
                    None => p,
                }
            }))
        }
        other => Err(error::base_error(format!(
            "unsupported outbound proxy protocol {other:?}; expected socks4 or socks5"
        ))),
    }
}

/// One token bucket of the `rate_limiter` create option (v0.6.9):
/// `(size, refill_time_ms, one_time_burst)`. Size is bytes for bandwidth
/// buckets, frames for ops buckets.
type TokenBucketSpec = (u64, u64, u64);

/// One direction of the `rate_limiter` create option.
struct RateLimiterSpec {
    bandwidth: Option<TokenBucketSpec>,
    ops: Option<TokenBucketSpec>,
}

/// Parsed `rate_limiter` create option (v0.6.9, mirrors the Python SDK's
/// `NetworkRateLimiter`): per-direction bandwidth/ops token buckets. Parsed up
/// front because the network builder closure cannot return an error.
struct NetworkRateLimiterSpec {
    egress: Option<RateLimiterSpec>,
    ingress: Option<RateLimiterSpec>,
}

fn parse_token_bucket(b: RHash, dir: &str, dim: &str) -> Result<TokenBucketSpec, Error> {
    let Some(size) = conv::opt::<u64>(b, "size")? else {
        return Err(error::base_error(format!(
            "rate_limiter {dir} {dim} bucket requires size:"
        )));
    };
    let Some(refill) = conv::opt::<u64>(b, "refill_time_ms")? else {
        return Err(error::base_error(format!(
            "rate_limiter {dir} {dim} bucket requires refill_time_ms:"
        )));
    };
    let burst = conv::opt::<u64>(b, "one_time_burst")?.unwrap_or(0);
    Ok((size, refill, burst))
}

fn parse_rate_limiter_direction(h: RHash, dir: &str) -> Result<RateLimiterSpec, Error> {
    Ok(RateLimiterSpec {
        bandwidth: conv::opt::<RHash>(h, "bandwidth")?
            .map(|b| parse_token_bucket(b, dir, "bandwidth"))
            .transpose()?,
        ops: conv::opt::<RHash>(h, "ops")?
            .map(|b| parse_token_bucket(b, dir, "ops"))
            .transpose()?,
    })
}

fn parse_rate_limiter(h: RHash) -> Result<NetworkRateLimiterSpec, Error> {
    Ok(NetworkRateLimiterSpec {
        egress: conv::opt::<RHash>(h, "egress")?
            .map(|d| parse_rate_limiter_direction(d, "egress"))
            .transpose()?,
        ingress: conv::opt::<RHash>(h, "ingress")?
            .map(|d| parse_rate_limiter_direction(d, "ingress"))
            .transpose()?,
    })
}

impl RateLimiterSpec {
    fn apply(
        self,
        mut rl: microsandbox_network::builder::RateLimiterBuilder,
    ) -> microsandbox_network::builder::RateLimiterBuilder {
        if let Some((size, refill_ms, burst)) = self.bandwidth {
            rl = rl.bandwidth(size, Duration::from_millis(refill_ms));
            if burst > 0 {
                rl = rl.bandwidth_burst(burst);
            }
        }
        if let Some((count, refill_ms, burst)) = self.ops {
            rl = rl.ops(count, Duration::from_millis(refill_ms));
            if burst > 0 {
                rl = rl.ops_burst(burst);
            }
        }
        rl
    }
}

struct TlsSpec {
    bypass: Vec<String>,
    verify_upstream: Option<bool>,
    intercepted_ports: Option<Vec<u16>>,
    block_quic: Option<bool>,
    upstream_ca_cert: Option<String>,
    intercept_ca_cert: Option<String>,
    intercept_ca_key: Option<String>,
}

fn parse_tls(t: RHash) -> Result<TlsSpec, Error> {
    Ok(TlsSpec {
        bypass: conv::opt_string_vec(t, "bypass")?,
        verify_upstream: conv::opt::<bool>(t, "verify_upstream")?,
        intercepted_ports: conv::opt::<Vec<u16>>(t, "intercepted_ports")?,
        block_quic: conv::opt::<bool>(t, "block_quic")?,
        upstream_ca_cert: conv::opt_string(t, "upstream_ca_cert")?,
        intercept_ca_cert: conv::opt_string(t, "intercept_ca_cert")?,
        intercept_ca_key: conv::opt_string(t, "intercept_ca_key")?,
    })
}

//--------------------------------------------------------------------------------------------------
// Network policy parsing (mirrors the Python binding's `apply_network`)
//--------------------------------------------------------------------------------------------------

/// Parse the `network_policy` option (a Hash normalized by the Ruby layer) into
/// a core `NetworkPolicy`. Returns `None` when the option is absent (bare
/// presets travel via the separate `network` key handled in `create`).
///
/// Composition order (first-match-wins per direction): bulk domain-deny rules
/// come first (so they outrank everything), then the caller's explicit
/// `rules`, then the profile/preset base's expansion LAST — the same order the
/// upstream CLI composes `--net` with explicit rules, so a narrower caller
/// override (e.g. `Rule.deny_dns`) beats the base's allows instead of dying
/// behind them. Per-direction defaults come from the explicit
/// `default_egress`/`default_ingress` when set, else the base's defaults, else
/// the asymmetric default (deny egress / allow ingress).
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

    // Optional base — composable profiles (v0.6.7) or a terminal preset,
    // mutually exclusive. Its rules and defaults seed the policy.
    let profile_names = conv::opt_string_vec(np, "profiles")?;
    let preset = conv::opt_string(np, "preset")?;
    if !profile_names.is_empty() && preset.is_some() {
        return Err(error::base_error(
            "network profiles: and preset: are mutually exclusive",
        ));
    }
    let base = if profile_names.is_empty() {
        preset.map(|p| network_preset(&p)).transpose()?
    } else {
        let profiles = profile_names
            .iter()
            .map(|s| network_profile_from_str(s))
            .collect::<Result<Vec<_>, Error>>()?;
        Some(NetworkPolicy::from_profiles(profiles))
    };
    // Caller's explicit rules go BEFORE the base expansion: under
    // first-match-wins, appending them after would make any override of a
    // base-allowed destination silently dead (a more permissive policy than
    // requested). Mirrors the upstream CLI's `--net` + rules composition.
    for rd in conv::opt_hash_vec(np, "rules")? {
        rules.push(parse_rule(rd)?);
    }

    let (preset_egress, preset_ingress) = match base {
        Some(mut base) => {
            rules.append(&mut base.rules);
            (Some(base.default_egress), Some(base.default_ingress))
        }
        None => (None, None),
    };

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
        "all" | "allow_all" | "allow-all" => NetworkPolicy::allow_all(),
        other => {
            return Err(error::base_error(format!(
                "unknown network preset {other:?} (expected none/allow_all; the removed \
                 public_only/non_local presets are replaced by composable profiles)"
            )))
        }
    })
}

fn network_profile_from_str(s: &str) -> Result<NetworkProfile, Error> {
    match s {
        "public" => Ok(NetworkProfile::Public),
        "private" => Ok(NetworkProfile::Private),
        "host" => Ok(NetworkProfile::Host),
        other => Err(error::base_error(format!(
            "unknown network profile {other:?} (expected public/private/host)"
        ))),
    }
}

/// Parsed `root_disk` create option. Integer shorthand = managed upper of N
/// MiB (mirrors Python's `root_disk=8192` and the CLI bare-size form); Hash =
/// explicit kind. Kind/field cross-validation (size on a disk image, etc.)
/// lives in the Ruby layer and the core builder — this stays a dumb carrier.
struct RootDiskSpec {
    kind: RootDiskKindSpec,
    size_mib: Option<u32>,
    format: Option<DiskImageFormat>,
    fstype: Option<String>,
    clone: Option<FlatClone>,
}

enum RootDiskKindSpec {
    Managed,
    Tmpfs,
    Disk(String),
    Flat,
}

impl RootDiskSpec {
    fn apply(self, mut d: RootDiskBuilder) -> RootDiskBuilder {
        match self.kind {
            RootDiskKindSpec::Managed => {}
            RootDiskKindSpec::Tmpfs => d = d.tmpfs(),
            RootDiskKindSpec::Disk(path) => d = d.disk_image(path),
            RootDiskKindSpec::Flat => d = d.flat(),
        }
        if let Some(mib) = self.size_mib {
            d = d.size(mib);
        }
        if let Some(f) = self.format {
            d = d.format(f);
        }
        if let Some(ft) = self.fstype {
            d = d.fstype(ft);
        }
        if let Some(c) = self.clone {
            d = d.clone_strategy(c);
        }
        d
    }
}

fn parse_root_disk(v: Value) -> Result<RootDiskSpec, Error> {
    if let Ok(mib) = u32::try_convert(v) {
        return Ok(RootDiskSpec {
            kind: RootDiskKindSpec::Managed,
            size_mib: Some(mib),
            format: None,
            fstype: None,
            clone: None,
        });
    }
    let Ok(h) = RHash::try_convert(v) else {
        return Err(error::base_error(
            "root_disk: expects an Integer (managed size in MiB) or a Hash \
             (use Microsandbox::RootDisk.managed/tmpfs/disk/flat)",
        ));
    };
    let kind = match conv::opt_string(h, "kind")?.as_deref() {
        None | Some("managed") => RootDiskKindSpec::Managed,
        Some("tmpfs") => RootDiskKindSpec::Tmpfs,
        Some("disk" | "disk-image" | "disk_image") => {
            let Some(path) = conv::opt_string(h, "path")? else {
                return Err(error::base_error("root_disk disk kind requires path:"));
            };
            RootDiskKindSpec::Disk(path)
        }
        Some("flat") => RootDiskKindSpec::Flat,
        Some(other) => {
            return Err(error::base_error(format!(
                "unknown root_disk kind {other:?} (expected managed/tmpfs/disk/flat)"
            )))
        }
    };
    let format = conv::opt_string(h, "format")?
        .map(|f| disk_format_from_str(&f))
        .transpose()?;
    // clone: flat-only private-disk clone strategy (v0.6.9). Validated here
    // (unknown values error) but kind cross-validation stays in the core
    // builder, matching the other fields.
    let clone = conv::opt_string(h, "clone")?
        .map(|c| match c.as_str() {
            "auto" => Ok(FlatClone::Auto),
            "copy" => Ok(FlatClone::Copy),
            "reflink" => Ok(FlatClone::Reflink),
            other => Err(error::base_error(format!(
                "unknown root_disk clone strategy {other:?} (expected auto/copy/reflink)"
            ))),
        })
        .transpose()?;
    Ok(RootDiskSpec {
        kind,
        size_mib: conv::opt_u32(h, "size_mib")?,
        format,
        fstype: conv::opt_string(h, "fstype")?,
        clone,
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
            timeout: conv::opt_f64(opts, "timeout")?
                .map(secs_to_duration)
                .transpose()?,
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

pub(crate) fn fs_entry_to_hash(entry: &FsEntry) -> RHash {
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

pub(crate) fn fs_metadata_to_hash(meta: &FsMetadata) -> RHash {
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
    // OCI writable-upper-layer accounting (Option<u64> → Integer or nil), for
    // sandboxes capped by `oci_upper_size`. Mirrors the Python/Node metrics.
    let _ = hash.aset("upper_used_bytes", m.upper_used_bytes);
    let _ = hash.aset("upper_free_bytes", m.upper_free_bytes);
    let _ = hash.aset("upper_host_allocated_bytes", m.upper_host_allocated_bytes);
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

/// Parse a Ruby-facing status name back into a core `SandboxStatus`. The Ruby
/// layer already validates the seven names (raising `ArgumentError`, the repo's
/// idiom for a bad argument value), so reaching the fallback here means the
/// native layer was called directly; keep it exhaustive rather than silent.
fn sandbox_status_from_str(status: &str) -> Result<SandboxStatus, Error> {
    match status {
        "created" => Ok(SandboxStatus::Created),
        "starting" => Ok(SandboxStatus::Starting),
        "running" => Ok(SandboxStatus::Running),
        "draining" => Ok(SandboxStatus::Draining),
        "paused" => Ok(SandboxStatus::Paused),
        "stopped" => Ok(SandboxStatus::Stopped),
        "crashed" => Ok(SandboxStatus::Crashed),
        other => Err(error::base_error(format!(
            "unknown sandbox status {other:?} (expected created/starting/running/draining/\
             paused/stopped/crashed)"
        ))),
    }
}

/// Build the core's `RestartOptions` from a string-keyed Hash
/// (`force`/`timeout`/`detached`). An absent `timeout` keeps the core's
/// ten-second graceful-shutdown default.
fn restart_options(opts: RHash) -> Result<RestartOptions, Error> {
    let mut options = RestartOptions {
        force: conv::opt_bool(opts, "force")?,
        detached: conv::opt_bool(opts, "detached")?,
        ..Default::default()
    };
    if let Some(secs) = conv::opt_f64(opts, "timeout")? {
        options.timeout = secs_to_duration(secs)?;
    }
    Ok(options)
}

/// Build the core's `DestroyOptions` from a string-keyed Hash
/// (`force`/`timeout`). An absent `timeout` keeps the core's ten-second
/// graceful-shutdown default.
fn destroy_options(opts: RHash) -> Result<DestroyOptions, Error> {
    let mut options = DestroyOptions {
        force: conv::opt_bool(opts, "force")?,
        ..Default::default()
    };
    if let Some(secs) = conv::opt_f64(opts, "timeout")? {
        options.timeout = secs_to_duration(secs)?;
    }
    Ok(options)
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
// Health & live modification (v0.6.6 / #1099)
//--------------------------------------------------------------------------------------------------

/// A `SandboxPingResult` as `{ name, latency_secs }`. Latency is a `Duration`;
/// we hand it to Ruby as f64 seconds and let the Ruby layer derive milliseconds
/// (the Python/Node SDKs expose only `latency_ms`).
fn ping_result_to_hash(result: &microsandbox::sandbox::SandboxPingResult) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("name", result.name.clone());
    let _ = hash.aset("latency_secs", result.latency.as_secs_f64());
    hash
}

/// A `SandboxTouchResult` as `{ name, activity_seq }`.
fn touch_result_to_hash(result: &microsandbox::sandbox::SandboxTouchResult) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("name", result.name.clone());
    let _ = hash.aset("activity_seq", result.activity_seq);
    hash
}

/// Drive a modify builder to a plan (dry-run or apply) and return it serialized
/// as a JSON string. Shared by `Sandbox::modify` and `SbHandle::modify`. The
/// canonical `SandboxModificationPlan` serde shape (snake_case keys, literal-space
/// enum strings) is parsed verbatim by the Ruby layer — matching the Python SDK's
/// raw-dict contract rather than re-casing it.
fn run_modify(builder: SandboxModificationBuilder, opts: RHash) -> Result<String, Error> {
    let patch = build_modify_patch(opts)?;
    let policy = conv::opt_string(opts, "policy")?.unwrap_or_else(|| "no_restart".to_string());
    let dry_run = conv::opt_bool(opts, "dry_run")?;
    let builder = apply_modify_policy(builder.with_patch(patch), &policy)?;
    let plan = block_on(async move {
        if dry_run {
            builder.dry_run().await
        } else {
            builder.apply().await
        }
    })
    .map_err(error::to_ruby)?;
    serde_json::to_string(&plan)
        .map_err(|e| error::base_error(format!("failed to serialize modification plan: {e}")))
}

/// Build the canonical `SandboxModificationPatch` from the modify Hash. Env and
/// label pairs are sorted so repeated calls with the same arguments produce the
/// same patch (and plan) ordering, mirroring the Python binding. As of v0.6.9
/// every patch field is surfaced (`root_disk_size` covers what the deprecated
/// CLI-only `oci_upper_size` used to mean).
fn build_modify_patch(opts: RHash) -> Result<SandboxModificationPatch, Error> {
    let mut env_pairs = conv::opt_string_map(opts, "env")?;
    env_pairs.sort();
    let mut label_pairs = conv::opt_string_map(opts, "labels")?;
    label_pairs.sort();

    Ok(SandboxModificationPatch {
        cpus: conv::opt_u8(opts, "cpus")?,
        max_cpus: conv::opt_u8(opts, "max_cpus")?,
        memory_mib: conv::opt_u32(opts, "memory")?,
        max_memory_mib: conv::opt_u32(opts, "max_memory")?,
        // v0.6.9 ("root disk resizing in every SDK"): grow the sandbox-owned
        // layered upper or flat root disk. Restart/next-start semantics and
        // backing-specific limits are enforced by the core.
        root_disk_size_mib: conv::opt_u32(opts, "root_disk_size")?,
        env: env_pairs
            .into_iter()
            .map(|(k, v)| EnvVar::new(k, v))
            .collect(),
        env_remove: conv::opt_string_vec(opts, "remove_env")?,
        labels: label_pairs,
        labels_remove: conv::opt_string_vec(opts, "remove_labels")?,
        workdir: conv::opt_string(opts, "workdir")?,
        secrets: parse_modify_secrets(opts)?,
        secrets_remove: conv::opt_string_vec(opts, "remove_secrets")?,
    })
}

/// Parse the `secrets` modify option (an Array of string-keyed Hashes normalized
/// by the Ruby layer) into canonical `SecretModificationPatch`es. Each Hash
/// carries `name` plus at most one of `env`/`store` (source) or `value` (raw
/// material) — the Ruby layer enforces that mutual exclusion — plus optional
/// `placeholder` and `allowed_hosts`. The raw `value` moves straight into the
/// `Zeroizing` field; it is never echoed in an error.
fn parse_modify_secrets(opts: RHash) -> Result<Vec<SecretModificationPatch>, Error> {
    let mut out = Vec::new();
    for h in conv::opt_hash_vec(opts, "secrets")? {
        let name = conv::opt_string(h, "name")?
            .ok_or_else(|| error::base_error("secret modification spec requires :name"))?;
        let env = conv::opt_string(h, "env")?;
        let store = conv::opt_string(h, "store")?;
        let value = conv::opt_string(h, "value")?;
        let source = match (env, store) {
            (Some(var), None) => Some(SecretSource::Env { var }),
            (None, Some(reference)) => Some(SecretSource::Store { reference }),
            (None, None) => None,
            // The Ruby layer rejects >1 source; guard defensively without
            // echoing any value.
            (Some(_), Some(_)) => {
                return Err(error::base_error(format!(
                    "secret {name:?}: \"env\" and \"store\" are mutually exclusive"
                )))
            }
        };
        out.push(SecretModificationPatch {
            name,
            source,
            value: value.unwrap_or_default().into(),
            placeholder: conv::opt_string(h, "placeholder")?,
            allowed_hosts: conv::opt_string_vec(h, "allowed_hosts")?,
        });
    }
    Ok(out)
}

/// Apply the parsed `policy` string to a modify builder. `no_restart` (default)
/// leaves the builder untouched; `next_start`/`restart` select those policies.
fn apply_modify_policy(
    builder: SandboxModificationBuilder,
    policy: &str,
) -> Result<SandboxModificationBuilder, Error> {
    match policy {
        "no_restart" => Ok(builder),
        "next_start" => Ok(builder.next_start()),
        "restart" => Ok(builder.restart()),
        other => Err(error::base_error(format!(
            "unknown policy {other:?}; expected \"no_restart\", \"next_start\", or \"restart\""
        ))),
    }
}

//--------------------------------------------------------------------------------------------------
// Pull progress (streaming image-pull during create_with_progress)
//--------------------------------------------------------------------------------------------------

/// Convert a core `PullProgress` event into a `{ "kind" => …, fields… }` Hash.
/// The match is exhaustive (no wildcard) so a future upstream variant surfaces
/// as a compile error rather than a silently-dropped event.
fn pull_progress_to_hash(p: &PullProgress) -> RHash {
    use PullProgress::*;
    let h = ruby().hash_new();
    match p {
        Resolving { reference } => {
            let _ = h.aset("kind", "resolving");
            let _ = h.aset("reference", reference.to_string());
        }
        Resolved {
            reference,
            manifest_digest,
            layer_count,
            total_download_bytes,
        } => {
            let _ = h.aset("kind", "resolved");
            let _ = h.aset("reference", reference.to_string());
            let _ = h.aset("manifest_digest", manifest_digest.to_string());
            let _ = h.aset("layer_count", *layer_count);
            let _ = h.aset("total_download_bytes", *total_download_bytes);
        }
        LayerDownloadProgress {
            layer_index,
            digest,
            downloaded_bytes,
            total_bytes,
        } => {
            let _ = h.aset("kind", "layer_download_progress");
            let _ = h.aset("layer_index", *layer_index);
            let _ = h.aset("digest", digest.to_string());
            let _ = h.aset("downloaded_bytes", *downloaded_bytes);
            let _ = h.aset("total_bytes", *total_bytes);
        }
        LayerDownloadComplete {
            layer_index,
            digest,
            downloaded_bytes,
        } => {
            let _ = h.aset("kind", "layer_download_complete");
            let _ = h.aset("layer_index", *layer_index);
            let _ = h.aset("digest", digest.to_string());
            let _ = h.aset("downloaded_bytes", *downloaded_bytes);
        }
        LayerDownloadVerifying {
            layer_index,
            digest,
        } => {
            let _ = h.aset("kind", "layer_download_verifying");
            let _ = h.aset("layer_index", *layer_index);
            let _ = h.aset("digest", digest.to_string());
        }
        LayerMaterializeStarted {
            layer_index,
            diff_id,
        } => {
            let _ = h.aset("kind", "layer_materialize_started");
            let _ = h.aset("layer_index", *layer_index);
            let _ = h.aset("diff_id", diff_id.to_string());
        }
        LayerMaterializeProgress {
            layer_index,
            bytes_read,
            total_bytes,
        } => {
            let _ = h.aset("kind", "layer_materialize_progress");
            let _ = h.aset("layer_index", *layer_index);
            let _ = h.aset("bytes_read", *bytes_read);
            let _ = h.aset("total_bytes", *total_bytes);
        }
        LayerMaterializeWriting { layer_index } => {
            let _ = h.aset("kind", "layer_materialize_writing");
            let _ = h.aset("layer_index", *layer_index);
        }
        LayerMaterializeComplete {
            layer_index,
            diff_id,
        } => {
            let _ = h.aset("kind", "layer_materialize_complete");
            let _ = h.aset("layer_index", *layer_index);
            let _ = h.aset("diff_id", diff_id.to_string());
        }
        StitchMergingTrees { layer_count } => {
            let _ = h.aset("kind", "stitch_merging_trees");
            let _ = h.aset("layer_count", *layer_count);
        }
        StitchWritingFsmeta => {
            let _ = h.aset("kind", "stitch_writing_fsmeta");
        }
        StitchWritingVmdk => {
            let _ = h.aset("kind", "stitch_writing_vmdk");
        }
        StitchComplete => {
            let _ = h.aset("kind", "stitch_complete");
        }
        Complete {
            reference,
            layer_count,
        } => {
            let _ = h.aset("kind", "complete");
            let _ = h.aset("reference", reference.to_string());
            let _ = h.aset("layer_count", *layer_count);
        }
    }
    h
}

/// A streaming image-pull + create session, from `Sandbox.create_with_progress`.
/// `recv` yields progress events; `result` awaits the booted sandbox. The pull
/// runs as a tokio task; the progress receiver needs `&mut self` and the join
/// handle is consumed once, so both sit behind a `tokio::Mutex`.
#[magnus::wrap(class = "Microsandbox::Native::PullSession", free_immediately, size)]
pub struct PullSession {
    progress: Arc<Mutex<PullProgressHandle>>,
    join: Arc<Mutex<Option<JoinHandle<MicrosandboxResult<microsandbox::Sandbox>>>>>,
}

impl PullSession {
    fn new(
        progress: PullProgressHandle,
        join: JoinHandle<MicrosandboxResult<microsandbox::Sandbox>>,
    ) -> Self {
        Self {
            progress: Arc::new(Mutex::new(progress)),
            join: Arc::new(Mutex::new(Some(join))),
        }
    }

    /// Next progress event as a Hash, or nil when the pull is finished.
    fn recv(&self) -> Result<Option<RHash>, Error> {
        let progress = Arc::clone(&self.progress);
        let event = block_on(async move { progress.lock().await.recv().await });
        Ok(event.map(|p| pull_progress_to_hash(&p)))
    }

    /// Await the booted sandbox. Call after draining `recv` (it joins the
    /// create task). Consumes the join handle, so it is callable only once.
    fn result(&self) -> Result<Sandbox, Error> {
        let join = Arc::clone(&self.join);
        let taken = block_on(async move { join.lock().await.take() });
        let handle = taken.ok_or_else(|| error::base_error("pull session result already taken"))?;
        let inner = block_on(handle)
            .map_err(|e| error::base_error(format!("sandbox creation task failed: {e}")))?
            .map_err(error::to_ruby)?;
        Ok(Sandbox::from_inner(inner))
    }
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

    /// The opaque, backend-assigned identity of the persisted sandbox this
    /// handle is bound to (v0.6.16). The lifecycle operations below refuse to
    /// act on a same-name replacement by comparing against it.
    fn id(&self) -> String {
        self.inner.id().to_string()
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
        block_on(self.inner.stop_with_timeout(secs_to_duration(secs)?)).map_err(error::to_ruby)
    }

    /// Force kill (SIGKILL) and wait.
    fn kill(&self) -> Result<(), Error> {
        block_on(self.inner.kill()).map_err(error::to_ruby)
    }

    /// Force kill, waiting up to `secs` for the process to disappear.
    fn kill_with_timeout(&self, secs: f64) -> Result<(), Error> {
        block_on(self.inner.kill_with_timeout(secs_to_duration(secs)?)).map_err(error::to_ruby)
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

    /// Connect when this exact sandbox is running, wait while it is starting,
    /// or start it when it is created/stopped/crashed. `opts` carries
    /// `detached`, which applies only when a start is actually required.
    fn connect_or_start(&self, opts: RHash) -> Result<Sandbox, Error> {
        let detached = conv::opt_bool(opts, "detached")?;
        let inner = block_on(async {
            if detached {
                self.inner.connect_or_start_detached().await
            } else {
                self.inner.connect_or_start().await
            }
        })
        .map_err(error::to_ruby)?;
        Ok(Sandbox::from_inner(inner))
    }

    /// Block until this exact sandbox reaches `status` (no built-in timeout),
    /// returning a fresh handle. A same-name replacement raises
    /// `SandboxReplacedError` instead of silently redirecting the wait.
    fn wait_for_status(&self, status: String) -> Result<SbHandle, Error> {
        let status = sandbox_status_from_str(&status)?;
        let handle = block_on(self.inner.wait_for_status(status)).map_err(error::to_ruby)?;
        Ok(SbHandle::from_inner(handle))
    }

    /// Stop and start this exact sandbox, returning the new live sandbox.
    /// `opts` carries `force`/`timeout`/`detached`.
    fn restart(&self, opts: RHash) -> Result<Sandbox, Error> {
        let options = restart_options(opts)?;
        let inner = block_on(self.inner.restart_with(options)).map_err(error::to_ruby)?;
        Ok(Sandbox::from_inner(inner))
    }

    /// Stop and remove this exact sandbox. `opts` carries `force`/`timeout`.
    fn destroy(&self, opts: RHash) -> Result<(), Error> {
        let options = destroy_options(opts)?;
        block_on(self.inner.destroy_with(options)).map_err(error::to_ruby)
    }

    /// Block until the sandbox reaches a terminal state; returns a stop-result
    /// Hash (name, status, exit_code, signal, observed_at_ms, source).
    fn wait_until_stopped(&self) -> Result<RHash, Error> {
        let result = block_on(self.inner.wait_until_stopped()).map_err(error::to_ruby)?;
        Ok(stop_result_to_hash(&result))
    }

    /// The sandbox's stored configuration as a JSON string (synchronous — the
    /// handle already carries it, no runtime round-trip). The Ruby layer parses
    /// it into a Hash for `#config`. Mirrors the Python/Node `config_json`.
    fn config_json(&self) -> String {
        self.inner.config_json().to_string()
    }

    /// Snapshot this (stopped) sandbox under a bare name (resolved under the
    /// snapshots directory). Returns the same SnapshotInfo Hash as
    /// `Snapshot.create`. Mirrors the Python/Node `handle.snapshot(name)`.
    /// (`snapshot_to` was removed upstream in v0.6.7 — use `Snapshot.create`
    /// with `dest_dir:` for explicit placement.)
    fn snapshot(&self, name: String) -> Result<RHash, Error> {
        let snap = block_on(self.inner.snapshot(&name)).map_err(error::to_ruby)?;
        Ok(crate::snapshot::snapshot_to_hash(&snap))
    }

    /// Health-check the guest agent without refreshing the idle timer. A stopped
    /// sandbox raises `SandboxNotRunningError` (the handle does not start it
    /// implicitly). Returns `{ name, latency_secs }`.
    fn ping(&self) -> Result<RHash, Error> {
        let result = block_on(self.inner.ping()).map_err(error::to_ruby)?;
        Ok(ping_result_to_hash(&result))
    }

    /// Explicitly refresh the idle-activity timer. A stopped sandbox raises
    /// `SandboxNotRunningError`. Returns `{ name, activity_seq }`.
    fn touch(&self) -> Result<RHash, Error> {
        let result = block_on(self.inner.touch()).map_err(error::to_ruby)?;
        Ok(touch_result_to_hash(&result))
    }

    /// Plan or apply a live sandbox modification (see `Sandbox::modify`). Returns
    /// the `SandboxModificationPlan` as a JSON string.
    fn modify(&self, opts: RHash) -> Result<String, Error> {
        run_modify(self.inner.modify(), opts)
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
    class.define_singleton_method(
        "create_with_progress",
        function!(Sandbox::create_with_progress, 2),
    )?;
    class.define_singleton_method(
        "connect_or_create",
        function!(Sandbox::connect_or_create, 2),
    )?;
    class.define_singleton_method("start", function!(Sandbox::start, 2))?;
    class.define_singleton_method("get", function!(Sandbox::get, 1))?;
    class.define_singleton_method("list", function!(Sandbox::list, 0))?;
    class.define_singleton_method("list_with", function!(Sandbox::list_with, 1))?;
    class.define_singleton_method("remove", function!(Sandbox::remove, 1))?;

    class.define_method("name", method!(Sandbox::name, 0))?;
    class.define_method("id", method!(Sandbox::id, 0))?;
    class.define_method("exec", method!(Sandbox::exec, 3))?;
    class.define_method("shell", method!(Sandbox::shell, 2))?;
    class.define_method("exec_stream", method!(Sandbox::exec_stream, 3))?;
    class.define_method("shell_stream", method!(Sandbox::shell_stream, 2))?;
    class.define_method("exec_default", method!(Sandbox::exec_default, 1))?;
    class.define_method(
        "exec_default_stream",
        method!(Sandbox::exec_default_stream, 1),
    )?;
    class.define_method("stop", method!(Sandbox::stop, 0))?;
    class.define_method("stop_and_wait", method!(Sandbox::stop_and_wait, 0))?;
    class.define_method("kill", method!(Sandbox::kill, 0))?;
    class.define_method("drain", method!(Sandbox::drain, 0))?;
    class.define_method("wait", method!(Sandbox::wait, 0))?;
    class.define_method("wait_for_status", method!(Sandbox::wait_for_status, 1))?;
    class.define_method("restart", method!(Sandbox::restart, 1))?;
    class.define_method("destroy", method!(Sandbox::destroy, 1))?;
    class.define_method("status", method!(Sandbox::status, 0))?;
    class.define_method("owns_lifecycle", method!(Sandbox::owns_lifecycle, 0))?;
    class.define_method("detach", method!(Sandbox::detach, 0))?;
    class.define_method("metrics", method!(Sandbox::metrics, 0))?;
    class.define_method("ping", method!(Sandbox::ping, 0))?;
    class.define_method("touch", method!(Sandbox::touch, 0))?;
    class.define_method("modify", method!(Sandbox::modify, 1))?;
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
    class.define_method("fs_read_stream", method!(Sandbox::fs_read_stream, 1))?;
    class.define_method("fs_write_stream", method!(Sandbox::fs_write_stream, 1))?;

    class.define_method("ssh_open_client", method!(Sandbox::ssh_open_client, 1))?;
    class.define_method(
        "ssh_prepare_server",
        method!(Sandbox::ssh_prepare_server, 1),
    )?;

    class.define_method("attach", method!(Sandbox::attach, 3))?;
    class.define_method("attach_default", method!(Sandbox::attach_default, 1))?;
    class.define_method("attach_shell", method!(Sandbox::attach_shell, 0))?;

    let handle = native.define_class("SandboxHandle", ruby.class_object())?;
    handle.define_method("name", method!(SbHandle::name, 0))?;
    handle.define_method("id", method!(SbHandle::id, 0))?;
    handle.define_method("status", method!(SbHandle::status, 0))?;
    handle.define_method("created_at_ms", method!(SbHandle::created_at_ms, 0))?;
    handle.define_method("updated_at_ms", method!(SbHandle::updated_at_ms, 0))?;
    handle.define_method("stop", method!(SbHandle::stop, 0))?;
    handle.define_method("stop_with_timeout", method!(SbHandle::stop_with_timeout, 1))?;
    handle.define_method("kill", method!(SbHandle::kill, 0))?;
    handle.define_method("kill_with_timeout", method!(SbHandle::kill_with_timeout, 1))?;
    handle.define_method("connect_or_start", method!(SbHandle::connect_or_start, 1))?;
    handle.define_method("wait_for_status", method!(SbHandle::wait_for_status, 1))?;
    handle.define_method("restart", method!(SbHandle::restart, 1))?;
    handle.define_method("destroy", method!(SbHandle::destroy, 1))?;
    handle.define_method("request_stop", method!(SbHandle::request_stop, 0))?;
    handle.define_method("request_kill", method!(SbHandle::request_kill, 0))?;
    handle.define_method("request_drain", method!(SbHandle::request_drain, 0))?;
    handle.define_method(
        "wait_until_stopped",
        method!(SbHandle::wait_until_stopped, 0),
    )?;
    handle.define_method("config_json", method!(SbHandle::config_json, 0))?;
    handle.define_method("snapshot", method!(SbHandle::snapshot, 1))?;
    handle.define_method("ping", method!(SbHandle::ping, 0))?;
    handle.define_method("touch", method!(SbHandle::touch, 0))?;
    handle.define_method("modify", method!(SbHandle::modify, 1))?;

    let session = native.define_class("PullSession", ruby.class_object())?;
    session.define_method("recv", method!(PullSession::recv, 0))?;
    session.define_method("result", method!(PullSession::result, 0))?;

    Ok(())
}
