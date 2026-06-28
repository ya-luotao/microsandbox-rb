# Changelog

All notable changes to this gem are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/). The gem follows its own
[semantic version](https://semver.org/), **independent of** the upstream
microsandbox runtime it embeds; each release notes the upstream runtime tag it
wraps, and the README's Versioning section keeps the full gem→runtime map.

## [Unreleased]

### Documentation

- **Calling-thread non-preemption is now documented** (issue #24). The GVL is
  released during native calls so *other* threads keep running, but the
  *calling* thread blocks uninterruptibly until the call returns —
  `Timeout::timeout`/`Thread#kill`/Ctrl-C can't interrupt it. README and
  DESIGN.md now state this and steer callers to the explicit `exec(timeout:)` /
  `shell(timeout:)` / `AgentClient(timeout:)` knobs for bounding long or
  unbounded/streaming calls, rather than `Timeout::timeout`.
- **`exec` `timeout: 0` semantics clarified** (issue #29). The `@param timeout`
  doc now notes the asymmetry: omit or `nil` means *no* timeout, while `0` is an
  immediate (zero) deadline that kills the command before any output and raises
  `ExecTimeoutError` — so use `nil`/omit, never `0`, for "no limit". Also noted
  that `exec_stream`/`shell_stream` accept `timeout:` but do **not** apply it
  (the streaming path discards it).
- **Streaming classes documented as single-pass / single-consumer** (issues #34,
  #31). `ExecHandle`, `LogStream`, `MetricsStream`, `FsReadStream`,
  `PullSession`, and `AgentStream` are `Enumerable` but drain a one-shot native
  channel: forward-only, not rewindable, and meant for one consumer on one
  thread. A second `each` (or a combinator after a partial drain) silently
  yields nothing. Noted on each class and in a README streaming caveat.
- **SSH `close` disconnect behavior documented** (issue #33). `SshClient#close` /
  `SftpClient#close` send the graceful protocol disconnect; relying on GC skips
  it (only the in-process server task is aborted). The block-less
  `open_client`/`sftp` docs now tell callers to `close` (or use the block form)
  for a clean disconnect.

### Internal

- **`DESIGN.md` refreshed** (issue #35). The stale runtime-pin references
  (`v0.5.7`/`v0.5.8`) now point at `v0.5.10` via `RUNTIME_VERSION`, and the
  hard-coded unit-example count is replaced with rot-proof phrasing.
- **RBS `initialize` convention made consistent** (issue #36). Native-backed,
  non-user-constructible value/handle/stream types no longer declare an internal
  `initialize` in `sig/microsandbox.rbs` (previously declared on 11 of them,
  omitted on peers of identical role); a top-of-file note records the convention.

## [0.8.1] - 2026-06-25

Gem-only release on the `v0.5.10` runtime (unchanged) — the two follow-ups to
`0.8.0`'s runtime adoption that review surfaced.

### Added

- **Per-bind-mount guest-write quota override** (issue #19). An inline `volumes:`
  bind mount now accepts a `quota_mib:` key to override the runtime's default
  guest-write budget (4 GiB as of `v0.5.10`, documented in `0.8.0`), e.g.
  `volumes: { "/out" => { bind: "/host/out", quota_mib: 16_384 } }`. The runtime
  still applies the 4 GiB default when unset; there is no unbounded option, so
  raise the value if a workload writes more. Valid on bind mounts only — the core
  rejects it on tmpfs/disk/named mounts (set a named volume's quota via
  `Volume.create(quota_mib:)`).

### Fixed

- **Stale local runtime is now re-provisioned instead of boot-failing**
  (issue #18). `Microsandbox.ensure_runtime!` short-circuited as soon as
  `installed?` was true, but that check confirms only that the `msb`/`libkrunfw`
  files *exist*, not that their version matches the runtime this gem build links.
  An older `msb` left in `~/.microsandbox` by a previous gem version therefore
  passed and then failed every `Sandbox.create` at boot on a host↔guest
  wire-protocol mismatch (e.g. a `v0.5.8` `msb` rejecting the `--config-fd` flag
  the `v0.5.10` runtime passes). `ensure_runtime!` now delegates to the
  idempotent, version-correcting installer on first use even when the runtime is
  present (a cheap `msb --version`; re-downloads only on absence/mismatch), so an
  upgrade-over-stale-install self-heals. Source-gem installs were already
  corrected at build time; this closes the gap for the precompiled-gem upgrade
  path. `MICROSANDBOX_NO_AUTO_INSTALL` still fully opts out.

## [0.8.0] - 2026-06-25

Adopts upstream runtime **`v0.5.10`** (up from the `v0.5.8` that `0.7.0` shipped).
Runtime-only bump — no public Ruby API change.

### Runtime

- **Adopted upstream `v0.5.10`** — the `microsandbox`/`microsandbox-network` git
  deps and `Microsandbox::RUNTIME_VERSION` now pin `v0.5.10`. This is the runtime
  bump originally attempted against `v0.5.9` during the `0.7.0` cycle and reverted:
  upstream's `v0.5.9` git tag predated its own crate-version bump, so the prebuilt
  runtime-provisioning path (`PREBUILT_VERSION = env!("CARGO_PKG_VERSION")`)
  resolved to `0.5.8` and downloaded a `msb` that rejected the new `--config-fd`
  flag the SDK unconditionally passes — every `Sandbox.create` died at boot.
  Upstream chose not to re-tag (most package registries forbid republishing a tag)
  and instead cut a clean **`v0.5.10`** whose tag carries the matching crate
  version `0.5.10` (upstream
  [#1029](https://github.com/superradcompany/microsandbox/issues/1029)). The bump
  carries the following upstream changes:
  - **Heartbeat no longer reclaims busy sandboxes** (upstream #1011). The host
    watchdog is now idle-detection only — a healthy sandbox with an active (or
    briefly starved) `exec` session is never killed for a stale heartbeat, the
    way it could be before.
  - **Launch config moved off the process argv** (upstream #1006). Bulky and
    secret-bearing config (the network blob, env) is handed to the sandbox over
    an inherited, unlinked-tempfile fd instead of `--`-flags, so it no longer
    leaks into `ps` / `/proc/<pid>/cmdline`.

### Changed

- **Directory bind mounts now carry a default 4 GiB guest-write quota**
  (upstream #1020). Any `volumes:` entry that binds a host directory (e.g.
  `volumes: { "/out" => "/host/out" }`) is given a `DEFAULT_BIND_QUOTA_MIB`
  (4096 MiB) guest-write budget by the v0.5.10 runtime when no explicit quota is
  set, so a sandbox can no longer fill the host disk through a bind mount. This
  is a **behavior change**: a workload that wrote more than 4 GiB to a bind mount
  under the `v0.5.8` runtime (`0.7.0`) will now fail with `ENOSPC`. The gem does
  not yet expose a per-bind quota override (named-volume `Volume.create` accepts
  `quota_mib:`, but the inline bind-mount path does not) — that escape hatch is a
  tracked follow-up. Until then, route large-write mounts through a named volume
  with an explicit `quota_mib:`.

## [0.7.0] - 2026-06-23

A large parity release closing the binding gaps an audit against the upstream
Python/Node SDKs (at the wrapped `v0.5.8` runtime) surfaced. The runtime tag is
unchanged. Two genuine bug fixes; the rest is newly-exposed surface plus a few
behavior corrections (see **Changed**).

### Fixed

- **Lossy UTF-8 decoding.** `LogEntry#text`, `ExecOutput#stdout`/`#stderr`,
  `ExecEvent#text`, `SshOutput#stdout`/`#stderr`, and `SftpClient#read_text` now
  scrub invalid byte sequences (replacing them with U+FFFD) so they always
  return a *valid* UTF-8 String — matching the Python/Node SDKs. Previously they
  re-tagged raw bytes as UTF-8 without transcoding, so captured output
  containing invalid UTF-8 produced strings that raised downstream (regex,
  concatenation, `JSON.generate`). Raw bytes remain available via `#data` /
  `#stdout_bytes` / `#stderr_bytes`.
- **`runtime_path=` spec** no longer pollutes the process-wide set-once
  `msb`-path `OnceLock` (it now stubs the native setter), removing an
  order-dependent failure in combined unit+integration runs.

### Added

- **Streaming image-pull progress** — `Sandbox.create_with_progress` returns a
  `PullSession` (an `Enumerable` of progress-event Hashes) with `#sandbox` for
  the booted sandbox.
- **Host-side volume filesystem** — `Volume.fs(name)` / `VolumeInfo#fs` return a
  `VolumeFs` (read/read_text/write/list/mkdir/remove_file/remove_dir/exists?/
  copy/rename/stat) that reads and writes a named volume without a running
  sandbox.
- **Streaming guest filesystem** — `FS#read_stream` / `FS#write_stream`
  (`FsReadStream`/`FsWriteSink`) for files too large to buffer in memory.
- **Full secrets surface** — `secrets:` entries accept `hosts:` / `host_patterns:`
  (wildcards) allow-lists, `placeholder:`, `require_tls:`, injection toggles
  (`inject_headers:`/`inject_basic_auth:`/`inject_query:`/`inject_body:`), and
  per-secret `on_violation:`; plus a sandbox-level `on_secret_violation:`. The
  block-variant actions accept both the underscore form (`block_and_log`) and the
  upstream kebab-case wire spelling (`block-and-log`) used by the CLI / Go SDK /
  config files; the bare `"passthrough"` string (passthrough-all-hosts, as in the
  Python/Node SDKs) is also accepted, so a policy copied from another SDK ports
  over unchanged.
- **Network configuration** — `Sandbox.create` now accepts `dns:` (nameservers/
  rebind_protection/query_timeout_ms), `tls:` (interception tuning incl. bypass
  patterns, intercepted ports, block_quic, and CA cert/key paths), `ipv4_pool:`/
  `ipv6_pool:`, `max_connections:`, and `trust_host_cas:`.
- **Create options** — `init:`/`init_with` (hand guest PID 1 to an init system),
  `ephemeral:` (auto-remove state on terminal), and disk-image `fstype:`.
  `fstype:` is rejected up front unless `image:` is a disk-image path (a local
  path ending in `.raw`/`.qcow2`/`.vmdk`); pairing it with an OCI reference no
  longer routes the ref through the disk-image builder and fails at boot.
- **Full mount options** — `volumes:` now supports `{ tmpfs: }`, `{ disk:,
  format:, fstype: }`, and per-mount `stat_virtualization:`/`host_permissions:`
  alongside the existing bind/named + ro/noexec/nosuid/nodev flags. The pre-0.7.0
  `options: %w[ro noexec]` array form is still honored (translated onto the
  boolean flags); an unrecognized token now raises rather than being silently
  dropped, so a requested read-only/noexec mount can't quietly become writable.
- **Snapshots** — `Snapshot.open`/`list_dir`/`reindex`, `SnapshotInfo#open`/
  `#remove`, and `SandboxHandle#snapshot`/`#snapshot_to`. `SnapshotInfo` now
  carries the full manifest (`image_manifest_digest`, `fstype`,
  `source_sandbox`, `labels`) on the artifact-opening paths.
- **`SandboxHandle#config` / `#config_json`** — read the stored sandbox config.
- **Metrics** — `upper_used_bytes`, `upper_free_bytes`,
  `upper_host_allocated_bytes` (OCI writable-upper-layer accounting).
- **`ImageDetail#config["labels"]`** — OCI config labels.
- **`Microsandbox.setup`** — customizable runtime install (`base_dir:`,
  `version:`, `force:`, `skip_verify:`); `force:` repairs a corrupt install.

### Changed

- **`exec`/`shell` stdin** is now a closed set: `nil`/`:null` = no stdin,
  `:pipe` = streaming pipe (streaming variants only), a String = bytes. An
  unrecognized Symbol now raises `ArgumentError` instead of being fed as its
  characters (so a mistaken `stdin: :null` no longer sends the literal `"null"`).
- **Write methods reject non-Strings.** `FS#write`, `SftpClient#write`,
  `ExecStdin#write`, `VolumeFs#write`, and `FsWriteSink#write` now raise
  `TypeError` for non-String data instead of silently writing its `to_s` form.
- **Agent connect timeout.** `AgentClient.connect_sandbox`/`connect_path`
  `timeout:` now treats `0` as an immediate deadline and raises on a
  negative/non-finite value, instead of silently falling back to the default.
- **Secrets shorthand** still accepts `{ env:, value:, host: }`; the validation
  message changed and a host allow-list is now required.

### Docs

- README/DESIGN implemented-surface corrected to match the binding (and to list
  the few secondary knobs still not exposed); assorted YARD fixes
  (`runtime_path=` set-once note, `VolumeInfo#kind` `:dir`, `create`'s
  `volumes:`/`from_snapshot:` params, `log_stream` `'all'` source); CHANGELOG
  compare links added for 0.5.9–0.5.12.

## [0.6.0] - 2026-06-23

This release puts the gem on its **own semantic version**, decoupled from the
upstream microsandbox runtime tag it embeds (which stays at `v0.5.8`). The
`0.5.x` lineage had stopped tracking upstream 1:1 — gem-only revisions and a
bundled breaking change (the `0.5.9 → 0.5.10` lifecycle split) had already
diverged the two numbers. `0.6.0` makes the split explicit; the gem version no
longer mirrors the upstream tag. See the README's **Versioning** section for the
gem→runtime map and the go-forward policy. No runtime change and no breaking API
change in this release.

### Added

- **`Microsandbox.runtime_version`** and the `Microsandbox::RUNTIME_VERSION`
  constant — report the upstream microsandbox runtime tag this gem build embeds
  (e.g. `"v0.5.8"`). The gem now versions itself independently of that tag, so
  this is the supported way to learn which runtime is wrapped.
  `spec/unit/version_spec.rb` pins the constant to the Cargo git tag so it can't
  drift.

## [0.5.12] - 2026-06-23

### Fixed

- **fork-safe tokio runtime.** The process-wide multi-threaded runtime is now
  tagged with the pid it was built under and rebuilt automatically after a
  `fork(2)`. A forking host (Solid Queue / Resque job servers, clustered Puma)
  used to inherit a runtime whose worker + I/O-driver threads do not survive the
  fork — `block_on` could still drive the calling thread, but background I/O (e.g.
  the agent-relay connection that streams `exec_stream` output) never ran, so
  long-lived operations stalled or the connection dropped mid-stream in the child.
  `runtime()` now detects the pid change and builds a fresh runtime for the child
  (the stale one is leaked, never dropped — dropping a runtime whose threads
  vanished across fork can hang on the shutdown join). No API change.

## [0.5.11] - 2026-06-23

### Added

- **Read-only / mount-option passthrough for volumes.** A volume spec Hash may
  now carry `ro:`/`readonly:`, `noexec:`, `nosuid:`, `nodev:`, or an explicit
  `options:` array, e.g. `volumes: { "/repos" => { bind: "/host/repos", ro: true } }`.
  The Ruby layer appends a 4th comma-joined options element to the normalized
  mount triple and the native ext applies the matching `MountBuilder` flags. RO is
  enforced both host-side (virtiofs rejects writes) and guest-side (kernel returns
  `EROFS`). Previously the gem could only request read-write mounts, so callers had
  to fake read-only with host `chmod -R a-w`. Backward compatible: String specs and
  option-less Hash specs serialize to the exact same 3-element triple as before.

## [0.5.10] - 2026-06-22

### Added

- **Streaming stdin pipe for `exec_stream`/`shell_stream`** (`stdin: :pipe`).
  Opens a writable `ExecHandle#stdin` sink (`ExecStdin`) lifted out of the core
  handle via `take_stdin`, distinct from the existing fixed-bytes `stdin:`
  buffer. This is the load-bearing primitive for driving an interactive
  long-running process (e.g. a `claude` CLI) over `exec_stream` from a host
  reactor. The published `0.5.9` shipped without it (`stdin: :pipe` was fed as
  the literal byte string `"pipe"`), so any consumer of the streaming sink must
  require `>= 0.5.10`.

Adopts the upstream **microsandbox `v0.5.8`** runtime (was `v0.5.7`), whose
backend-routing rewrite (upstream PR #754) both adds new surface and reshapes the
sandbox lifecycle.

### Changed

- **BREAKING — sandbox lifecycle split (mirrors the official Python/Node SDKs).**
  Upstream `v0.5.8` split the lifecycle across a live `Sandbox` and a lightweight
  `SandboxHandle`. The gem follows suit:
  - The live `Microsandbox::Sandbox` (from `Sandbox.create`/`Sandbox.start`) now
    exposes `#stop`, `#stop_and_wait`, `#kill`, `#drain`, `#wait`, `#status`,
    `#detach`, and `#owns_lifecycle?`. `#stop` and `#kill` **no longer take a
    `timeout:`** keyword; `#stop` performs the graceful SIGTERM→SIGKILL
    escalation (10s default) the official SDKs use.
  - `#request_stop`, `#request_kill`, `#request_drain`, `#wait_until_stopped`,
    and a custom stop/kill timeout have **moved off** the live `Sandbox` onto the
    controllable `Microsandbox::SandboxHandle` (see Added).
- **BREAKING — `Sandbox.get`/`.list`/`.list_with` now return a controllable
  `Microsandbox::SandboxHandle`** instead of a read-only `SandboxInfo`. The
  handle keeps the same metadata accessors (`name`, `status`, `created_at`,
  `updated_at`, `running?`, `stopped?`). `Microsandbox::SandboxInfo` remains as a
  deprecated constant alias for `SandboxHandle`.
- `SandboxStatus` gained two values, `:created` and `:starting` (cloud-only
  today), so `#status` may now return them.

### Added

- **Backend routing** — `Microsandbox.set_default_backend(kind, url:, api_key:,
  profile:)`, `Microsandbox.with_backend(kind, …) { … }` (a scoped, restoring
  override), and `Microsandbox.default_backend_kind`. Without configuration the
  runtime resolves a backend lazily from `MSB_BACKEND`, `MSB_API_URL` +
  `MSB_API_KEY`, `MSB_PROFILE`, and `~/.microsandbox/config.json` (honoring
  `MSB_CONFIG_PATH`). The cloud backend supports a documented subset
  (create/start/stop/remove/get/list, one-shot exec, follow log streaming);
  unsupported operations raise `UnsupportedError`. Under a cloud backend,
  `Sandbox.create`/`.start` skip local `msb`/`libkrunfw` runtime provisioning
  (it isn't needed), so cloud-only hosts no longer trigger a spurious download.
- **`Microsandbox::SandboxHandle`** — the controllable handle returned by
  `Sandbox.get`/`.list`/`.list_with`: `#stop`, `#stop_with_timeout(secs)`,
  `#kill`, `#kill_with_timeout(secs)`, `#request_stop`, `#request_kill`,
  `#request_drain`, `#wait_until_stopped` (→ `SandboxStopResult`), plus the
  metadata accessors. Mirrors the official SDKs' `SandboxHandle`.
- **`Sandbox#stop_and_wait` / `Sandbox#wait`** — return a `Microsandbox::ExitStatus`
  (`#exit_code`, `#success?`). **`Sandbox#drain`** triggers a graceful drain.
  **`Sandbox#status`** fetches the live status from the backend.
- **`Microsandbox.libkrunfw_path=`** — overrides the `libkrunfw` shared-library
  path (SDK tier of the resolver; `MSB_LIBKRUNFW_PATH` still wins). Mirrors
  `runtime_path=`.
- **`Microsandbox::CloudHttpError`** (`cloud-http`) and
  **`Microsandbox::UnsupportedError`** (`unsupported`) — distinct from the
  existing `UnsupportedOperationError`.

### Fixed

- **Reject invalid durations with a clear `ArgumentError`** — negative, `NaN`,
  and infinite values passed to `timeout:` (`exec`/`shell`),
  `SandboxHandle#stop_with_timeout`/`#kill_with_timeout`, `replace_with_timeout:`,
  and `metrics_stream(interval:)` are rejected in Ruby before reaching the native
  layer, where they would otherwise panic across the FFI boundary
  (`Duration::from_secs_f64` panics on exactly those inputs).
- **Reject contradictory `image:` + `from_snapshot:`** — `Sandbox.create` now
  raises `ArgumentError` when both are given (a sandbox boots from exactly one
  rootfs source), failing fast instead of after a runtime round-trip.

## [0.5.9] - 2026-06-18

Closes the remaining roadmap items, bringing the binding surface to parity with
the official Python/Node/Go SDKs (still wrapping the same upstream core,
`v0.5.7`).

### Added

- **Rootfs patches** — `Sandbox.create(patches: [...])` applies modifications to
  the root filesystem before boot, built with the new `Microsandbox::Patch`
  factory: `Patch.text`/`file`/`append`/`copy_file`/`copy_dir`/`symlink`/`mkdir`/
  `remove`. Mirrors the `Patch` factory in the official SDKs. (OverlayFS/bind
  roots only — not disk images.)
- **Custom per-rule network policies** — `Sandbox.create(network:)` now accepts,
  besides the existing preset names, a `Microsandbox::NetworkPolicy` or a Hash
  describing an ordered allow/deny rule list with per-direction defaults and bulk
  domain denials. New `Microsandbox::NetworkPolicy` (`public_only`/`none`/
  `allow_all`/`non_local`/`custom`), `Microsandbox::Rule` (`allow`/`deny`), and
  `Microsandbox::Destination` (`any`/`ip`/`cidr`/`domain`/`domain_suffix`/
  `group`, plus shorthand-string classification) factories. Destination
  classification and rule composition mirror the official binding exactly.
- **Raw agent client** — `Microsandbox::AgentClient.connect_sandbox`/
  `connect_path`/`socket_path` open the byte-level transport to a sandbox's
  `agentd` relay socket: `request`, `stream` (→ `Microsandbox::AgentStream`,
  `Enumerable` over `Microsandbox::AgentFrame`), `send_frame`, `ready_bytes`,
  `close`, with the `FLAG_TERMINAL`/`FLAG_SESSION_START`/`FLAG_SHUTDOWN` frame
  flags. Mirrors the official `AgentClient`.
- **SSH** — `Sandbox#ssh` returns a `Microsandbox::SshOps` to `open_client`
  (→ `Microsandbox::SshClient`: `exec` → `Microsandbox::SshOutput`, `attach`,
  `sftp` → `Microsandbox::SftpClient` with `read`/`write`/`mkdir`/`remove_file`/
  `remove_dir`/`rename`/`symlink`/`real_path`/`read_link`, `close`) or
  `prepare_server` (→ `Microsandbox::SshServer`: `serve_connection`, `close`).
- **Interactive attach** — `Sandbox#attach(command, args, …)` and
  `Sandbox#attach_shell` couple the host terminal (raw mode, SIGWINCH) to a
  command (or the default shell) in the sandbox and return its exit code. For
  CLI use — requires a real TTY.
- RBS signatures for all of the above.

### Notes

- Network policy: a `preset` and custom `rules:`/`default_egress:`/`default_ingress:`
  are mutually exclusive (a preset already defines its rules and defaults); a
  preset may still be layered with `deny_domains:`/`deny_domain_suffixes:`. A
  hand-written rule Hash accepts the singular `protocol:`/`port:` keys (the
  spelling the Go/Python `PolicyRule` use) as well as the plural forms. The
  deny-list-only shorthand (`network: { deny_domains: [...] }`) keeps the rest of
  the network reachable (permissive defaults), matching the official SDKs.

## [0.5.8] - 2026-06-17

Closes the `Sandbox`-class lifecycle gap with the official Python/Node/Go SDKs
and adds private/authenticated registry support plus first-use runtime
auto-provisioning (the keystone for precompiled gems). Wraps the same upstream
core (`v0.5.7`); this is a gem-only revision atop it.

### Added

- Asynchronous lifecycle controls on `Microsandbox::Sandbox`: `request_stop`,
  `request_kill`, `request_drain` (send the request without waiting),
  `wait_until_stopped` (blocks and returns a `Microsandbox::SandboxStopResult`),
  `owns_lifecycle?`, and `detach` (disarm stop-on-drop and keep the sandbox
  running). Mirrors the official SDKs' lifecycle surface.
- `Microsandbox::SandboxStopResult` value object (`name`, `status`, `exit_code`,
  `signal`, `source`, `observed_at`, `stopped?`/`crashed?`).
- `Microsandbox::Sandbox.list_with(labels:)` — list sandboxes filtered by
  AND-matched labels.
- `Microsandbox.all_sandbox_metrics` — latest metrics for every running
  sandbox, keyed by name (mirrors `all_sandbox_metrics`/`allSandboxMetrics`).
- `Microsandbox::VolumeAlreadyExistsError`, mapped from the core
  `VolumeAlreadyExists` variant.
- Streaming observability: `Sandbox#metrics_stream(interval:)` →
  `Microsandbox::MetricsStream` and `Sandbox#log_stream(sources:, since_ms:,
  from_cursor:, until_ms:, follow:)` → `Microsandbox::LogStream`, both
  `Enumerable` (over `Metrics` / `LogEntry`) draining the underlying core stream
  with the GVL released.
- Snapshots: `Microsandbox::Snapshot.create`/`get`/`list`/`remove`/`verify`/
  `export`/`import` with `SnapshotInfo` and `SnapshotVerifyReport` value
  objects. Boot from a snapshot via `Sandbox.create(from_snapshot:)`.
- Expanded `Sandbox.create` options: `log_level`, `quiet_logs`, `security`
  (`default`/`restricted`), `oci_upper_size`, `max_duration`, `idle_timeout`,
  `ports_udp`, `rlimits`, `pull_policy` (`always`/`if-missing`/`never`),
  `secrets` (placeholder-protected, TLS-substituted per allowed host), and the
  `allow_all`/`non_local` network policy presets (alongside the existing
  `public_only`/`none`).
- Per-exec resource limits: `rlimits:` on `Sandbox#exec`/`#shell`/`#exec_stream`/
  `#shell_stream` (e.g. `rlimits: { nofile: 65_535, cpu: [10, 20] }`).
- CI now runs the real-microVM integration suite (`spec/integration`) on a
  KVM-enabled runner, so the Rust↔core round-trip is exercised in automation —
  not just compilation and unit tests.
- Registry authentication for `Sandbox.create`: `registry_auth: { username:,
  password: }` (the password may be a token) for private/authenticated
  registries and to lift Docker Hub's anonymous rate limit, plus
  `registry_insecure:` (plain HTTP) and `registry_ca_certs:` (a PEM String or
  Array) for self-hosted registries. Mirrors the Python/Node `registry_auth`
  surface; without it the core's default resolution (OS keyring, global config,
  `~/.docker/config.json`) still applies.
- `Microsandbox.ensure_runtime!` — provisions the `msb` runtime + `libkrunfw` on
  first use, called automatically by `Sandbox.create`/`start`. This makes
  **precompiled platform gems** usable without a manual `install` step (a
  precompiled-gem user never ran the source build, so the runtime is fetched
  lazily by the running host's arch). Opt out with `MICROSANDBOX_NO_AUTO_INSTALL`.

### Changed

- The `cross-gems` release job now installs `libcap-ng-dev:arm64` via Debian
  multiarch for the `aarch64-linux` cross-build (the extension links `-lcap-ng`
  for the target arch). Precompiled gems remain `workflow_dispatch`-only and are
  promoted to the publish path manually after per-platform validation.

## [0.5.7] - 2026-06-17

Initial release of the Ruby SDK — native bindings (magnus + rb-sys) over the
microsandbox runtime, aligned with the official Python/Node/Go SDKs.

### Added

- `Microsandbox::Sandbox` lifecycle: `create` (with block-scoped auto-stop),
  `start`, `get`, `list`, `remove`, `stop`, `kill`.
- Command execution: `Sandbox#exec` and `Sandbox#shell` returning
  `Microsandbox::ExecOutput` (`exit_code`, `success?`, `stdout`/`stderr`,
  `stdout_bytes`/`stderr_bytes`), with `cwd`, `user`, `env`, `timeout`, `tty`,
  and `stdin` options.
- Streaming execution: `Sandbox#exec_stream`/`#shell_stream` returning an
  `Enumerable` `Microsandbox::ExecHandle` over `Microsandbox::ExecEvent`s, with
  a stdin sink (`#stdin`), `#wait`/`#collect`, and `#signal`/`#kill`/`#resize`.
- OCI image-cache management: `Microsandbox::Image.get`/`list`/`inspect`/
  `remove`/`prune` with `ImageInfo`/`ImageDetail`/`ImagePruneReport`.
- Named volumes: `Microsandbox::Volume.create`/`get`/`list`/`remove` with
  `VolumeInfo`, plus `volumes:` mounts (`{ bind: }` / `{ named: }`) and
  `from_snapshot:` boot in `Sandbox.create`.
- Guest filesystem (`Sandbox#fs`): `read`, `read_text`, `write`, `list`,
  `mkdir`, `remove`, `remove_dir`, `copy`, `rename`, `exists?`, `stat`,
  `copy_from_host`, `copy_to_host`, with `FsEntry`/`FsMetadata` value objects.
- Observability: `Sandbox#metrics` (`Microsandbox::Metrics`) and `Sandbox#logs`
  (`Microsandbox::LogEntry`).
- Create options: `image`, `cpus`, `memory`, `env`, `workdir`, `shell`, `user`,
  `hostname`, `labels`, `scripts`, `entrypoint`, `ports`, `network`
  (`public_only`/`none`), `detached`, `replace`/`replace_with_timeout`.
- Typed error hierarchy rooted at `Microsandbox::Error`, each carrying a stable
  `#code`, mapped from the core `MicrosandboxError`.
- Runtime management: `Microsandbox.install`, `.installed?`, `.runtime_path`,
  `.runtime_path=`.
- The GVL is released during blocking sandbox calls so other Ruby threads keep
  running.

### Known limitations / roadmap

- Streaming logs/metrics (`log_stream`, `metrics_stream`), snapshot
  creation/management, SSH, the raw agent client, and fine-grained
  networking/secrets/patches are not yet exposed. The native layer is
  structured to add them module-by-module.
- The release pipeline (`.github/workflows/release.yml`) builds precompiled
  platform gems via `rake-compiler-dock` and publishes via Trusted Publishing;
  the `arm64-darwin` cross-build needs validation on the first tagged run (the
  core crate has Apple-native deps). Until precompiled gems are published,
  installing from source requires a Rust toolchain (stable >= 1.91).

[Unreleased]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.12...v0.6.0
[0.5.12]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.11...v0.5.12
[0.5.11]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.10...v0.5.11
[0.5.10]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.9...v0.5.10
[0.5.9]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.8...v0.5.9
[0.5.8]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.7...v0.5.8
[0.5.7]: https://github.com/superradcompany/microsandbox/releases/tag/v0.5.7
