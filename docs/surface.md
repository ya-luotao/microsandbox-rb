# Supported surface

The binding covers the official-SDK surface of the upstream Rust core. This
page is the authoritative scope statement; `sig/microsandbox.rbs` is the typed
counterpart, and [DESIGN.md](../DESIGN.md) explains how the layers fit.

## Implemented

- **Sandbox lifecycle** — the live `Sandbox` (`stop`/`stop_and_wait`/`kill`/
  `drain`/`wait`/`status`/`detach`/`owns_lifecycle?`), the `SandboxHandle`
  controls from `Sandbox.get` (`stop_with_timeout`/`request_stop`/
  `request_kill`/`request_drain`/`wait_until_stopped`/`config`/`config_json`/
  `snapshot`), the cursor-paginated `list`/`list_with` with label filters, and
  the convergent lifecycle (`connect_or_create`, `#id`, `wait_for_status`,
  `restart`, `destroy`, `SandboxHandle#connect_or_start`,
  `SandboxReplacedError`).
- **Backend routing** — `set_default_backend`/`with_backend`/
  `default_backend_kind`/`default_backend_info`.
- **Execution** — `exec`/`shell` (collected and streaming), the default
  workload (`exec_default`/`exec_default_stream`/`attach_default`, `cmd:`),
  interactive `attach`/`attach_shell`, per-call `rlimits`.
- **Guest filesystem** — the full API including streaming `read_stream`/
  `write_stream`.
- **Observability** — per-sandbox `metrics`, `Microsandbox.all_sandbox_metrics`,
  streaming `metrics_stream`/`log_stream`, `logs`, `ping`/`touch`.
- **Live modification** — `modify` with `dry_run:` and `policy:`: CPU/memory
  resize (`cpus`/`max_cpus`/`memory`/`max_memory`), root-disk growth
  (`root_disk_size`, MiB), `env`/`remove_env`, `labels`/`remove_labels`,
  `workdir`, and secret rotation (`secrets`/`remove_secrets`).
- **OCI image cache** — `Image.get`/`list`/`inspect`/`remove`/`prune`, image
  archives (`Image.load`/`Image.save`), streaming pull progress
  (`Sandbox.create_with_progress` → `PullSession`).
- **Named volumes** — `Volume.create`/`get`/`list`/`remove`/`get_default`, plus
  host-side `Volume.fs`/`VolumeInfo#fs` read/write.
- **Snapshots** — create (disk scope, or `full:` for a resumable checkpoint;
  `guest_flush:`)/open/list/list_dir/reindex/verify/save/load, opt-in
  `record_integrity:`, `SnapshotInfo#reference`/`#reference_kind`.
  Selectors follow runtime `v0.7` snapshot groups (a bare name selects a group
  head; `group:member`, id, digest or path select one artifact — see
  [images.md](images.md#snapshots)); the group surface itself (`group:`, head
  selection) is not bound yet.
- **Restore** — `Sandbox.restore(snapshot, name:)` boots a new (upstream:
  detached) sandbox from a snapshot, with the destination options `cpus`/
  `memory`/`user`/`log_level`/`max_duration`/`idle_timeout`/`volumes`/`ports`/
  `disable_network`/`cow_memory` (`forked` deprecated)/`disk_only`/
  `snapshot_base`/`allow_missing_resources`/`external_mount_policy` (see
  [images.md](images.md#restoring-a-snapshot)). It replaced create's
  `from_snapshot:`.
- **Rootfs patches** — `Microsandbox::Patch` (text/file/append/copy_file/
  copy_dir/symlink/mkdir/remove) via `create(patches:)`.
- **Root disk** — structured `root_disk:` (managed / tmpfs / disk / flat via
  `Microsandbox::RootDisk`), `follow_root_symlinks:`; `oci_upper_size:` is the
  deprecated alias for a managed `root_disk:` size.
- **Network configuration** — composable profiles, custom per-rule
  `Microsandbox::NetworkPolicy`/`Rule`/`Destination`, custom DNS (`dns:`),
  TLS-interception tuning (`tls:`), guest address pools (`ipv4_pool:`/
  `ipv6_pool:`), `max_tcp_connections`/`max_udp_connections` (the deprecated
  `max_connections` aliases the TCP cap), `trust_host_cas`, `strict` hostname mode,
  the HTTP deny response (`http:` — JSON or text `403`, custom messages, or
  off; see [configuration.md](configuration.md#http-deny-response)),
  outbound SOCKS4/SOCKS5 `proxy:` (`OutboundProxy`/`SecretSource`),
  `rate_limiter:`, `vsock:`.
- **Secrets** — per-secret `allow:` lists (exact hosts, `*.example.com`
  wildcards, or `"*"` for any host), `allow_placeholder_for:` hosts that may
  receive the unchanged placeholder, `placeholder:`, `require_tls_identity:`,
  `substitution:` locations (headers / named header fields / query / body),
  per-secret `violation_action:` and the sandbox-wide `secret_violation_action:`
  (`block` / `block_and_log` / `block_and_terminate`). See
  [configuration.md](configuration.md#secrets) for the 0.17 → 0.18 key map;
  the removed keys and `on_secret_violation:` raise with their replacement.
- **SSH** — `Sandbox#ssh` → `SshClient`/`SftpClient`/`SshServer`, with
  `inactivity_timeout:`.
- **Raw agent client** — `Microsandbox::AgentClient` → `AgentStream`/
  `AgentFrame`.
- **Runtime provisioning** — `install(force:)`/`installed?`/`ensure_runtime!`/
  `runtime_path`/`libkrunfw_path`, `runtime_info` → `RuntimeInfo` (the
  resolved `msb` + `libkrunfw` pair, its gem-classified `origin` and embedded
  `version`), customizable via `Microsandbox.setup`; the version-aware
  bootstrap (the `msb` must be exactly `RUNTIME_VERSION`); the companion
  `microsandbox-rb-binaries` gem.
- **Registries** — `registry_auth`/`registry_insecure`/`registry_ca_certs` on
  `create`.
- **Errors** — the typed hierarchy in [errors.md](errors.md).
- **Process model** — the SDK may be used before and after `fork`; objects
  created before a fork are refused in the child with `ForkedHandleError`
  (see [runtime.md](runtime.md#forking-puma-resque-solid-queue)). On macOS a
  forked child must not build network clients — cloud backends, image pulls,
  `Image.load`, runtime install — or it crashes (see
  [runtime.md](runtime.md#macos-no-network-clients-in-a-forked-child)).

Create options span resources (`cpus`/`memory`/`max_cpus`/`max_memory`),
`env`/`workdir`/`labels`/`user`/`hostname`/`shell`, named `scripts`, the image
`entrypoint`/`cmd` overrides, `init`/`ephemeral`,
disk-image `fstype`, `ports`/`ports_udp`, network policy + config,
`log_level`/`quiet_logs`/`security`/`rlimits`/`pull_policy`/`secrets`/`patches`/`volumes`
(bind/named/tmpfs/disk with mount policies, `uid`/`gid`, `quota_mib`),
`secret_violation_action`, `idle_timeout`/`max_duration`, `detached`, and
`replace`/`replace_with_timeout`. Two keywords remain only to fail loudly
since 0.18.0: `from_snapshot` and `on_secret_violation`.

## Not yet exposed

A few secondary upstream knobs are not yet exposed: per-published-port host
bind address (ports always bind loopback), network interface overrides, and
inline named-volume create-mode (pre-create the volume with `Volume.create`,
then mount it with `{ named: "…" }`).

Restore does not yet take the network policy, security profile, vsock routes,
connection caps, UDP ports, captured-disk selection (`captured`), resource
inheritance (`dangerously_inherit_resources`), `guest_clock`, or a progress
stream; snapshot groups, live branches/forks and `restore_warnings` are not
bound either (planned for 0.19.0).
