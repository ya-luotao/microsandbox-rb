# Changelog

All notable changes to this gem are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the version tracks the
upstream microsandbox runtime.

## [Unreleased]

Closes the `Sandbox`-class lifecycle gap with the official Python/Node/Go SDKs.

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

[0.5.7]: https://github.com/superradcompany/microsandbox/releases/tag/v0.5.7
