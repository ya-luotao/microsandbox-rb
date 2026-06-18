# Changelog

All notable changes to this gem are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the version tracks the
upstream microsandbox runtime.

## [Unreleased]

### Fixed

- **Reject invalid durations with a clear `ArgumentError`** — negative, `NaN`,
  and infinite values passed to `timeout:` (`exec`/`shell`), `stop`/`kill`
  timeouts, `replace_with_timeout:`, and `metrics_stream(interval:)` are now
  rejected in Ruby before reaching the native layer, where they would otherwise
  panic across the FFI boundary (`Duration::from_secs_f64` panics on exactly
  those inputs).
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

[Unreleased]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.8...HEAD
[0.5.8]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.7...v0.5.8
[0.5.7]: https://github.com/superradcompany/microsandbox/releases/tag/v0.5.7
