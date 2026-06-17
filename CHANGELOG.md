# Changelog

All notable changes to this gem are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the version tracks the
upstream microsandbox runtime.

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
