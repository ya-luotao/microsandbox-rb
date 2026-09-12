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
- **Live modification** — `modify` with `dry_run:`, `policy:`, CPU/memory
  resize, root-disk growth, env/labels/workdir, secret rotation.
- **OCI image cache** — `Image.get`/`list`/`inspect`/`remove`/`prune`, image
  archives (`Image.load`/`Image.save`), streaming pull progress
  (`Sandbox.create_with_progress` → `PullSession`).
- **Named volumes** — `Volume.create`/`get`/`list`/`remove`/`get_default`, plus
  host-side `Volume.fs`/`VolumeInfo#fs` read/write.
- **Snapshots** — create/open/list/list_dir/reindex/verify/save/load, boot from
  snapshot, opt-in `record_integrity:`.
- **Rootfs patches** — `Microsandbox::Patch` (text/file/append/copy_file/
  copy_dir/symlink/mkdir/remove) via `create(patches:)`.
- **Root disk** — structured `root_disk:` (managed / tmpfs / disk / flat via
  `Microsandbox::RootDisk`), `follow_root_symlinks:`.
- **Network configuration** — composable profiles, custom per-rule
  `Microsandbox::NetworkPolicy`/`Rule`/`Destination`, DNS, TLS interception,
  IPv4/IPv6 pools, `max_connections`, `trust_host_cas`, `strict` hostname mode,
  outbound SOCKS4/SOCKS5 `proxy:` (`OutboundProxy`/`SecretSource`),
  `rate_limiter:`, `vsock:`.
- **Secrets** — multi-host / wildcard allow-lists, injection toggles,
  per-secret and sandbox-level violation policy.
- **SSH** — `Sandbox#ssh` → `SshClient`/`SftpClient`/`SshServer`, with
  `inactivity_timeout:`.
- **Raw agent client** — `Microsandbox::AgentClient` → `AgentStream`/
  `AgentFrame`.
- **Runtime provisioning** — `install`/`installed?`/`ensure_runtime!`/
  `runtime_path`/`libkrunfw_path`, customizable via `Microsandbox.setup`; the
  companion `microsandbox-rb-binaries` gem.
- **Registries** — `registry_auth`/`registry_insecure`/`registry_ca_certs` on
  `create`.
- **Errors** — the typed hierarchy in [errors.md](errors.md).

Create options span resources (`cpus`/`memory`/`max_cpus`/`max_memory`),
`env`/`workdir`/`labels`/`user`/`hostname`/`shell`, `init`/`ephemeral`,
disk-image `fstype`, `ports`/`ports_udp`, network policy + config,
`log_level`/`security`/`rlimits`/`pull_policy`/`secrets`/`patches`/`volumes`
(bind/named/tmpfs/disk with mount policies, `uid`/`gid`, `quota_mib`),
`idle_timeout`/`max_duration`, `from_snapshot`, `detached`, and
`replace`/`replace_with_timeout`.

## Not yet exposed

A few secondary upstream knobs are not yet exposed: per-published-port host
bind address (ports always bind loopback), network interface overrides, and
inline named-volume create-mode (pre-create the volume with `Volume.create`,
then mount it with `{ named: "…" }`).
