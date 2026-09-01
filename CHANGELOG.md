# Changelog

All notable changes to this gem are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/). The gem follows its own
[semantic version](https://semver.org/), **independent of** the upstream
microsandbox runtime it embeds; each release notes the upstream runtime tag it
wraps, and the README's Versioning section keeps the full gem→runtime map.

## [Unreleased]

Adopts upstream runtime **`v0.6.14` → `v0.6.15`**.

### Added

- Per-mount fallback ownership: a bind or named mount in `volumes:` accepts
  `uid:`/`gid:`, pinning the guest owner presented for host files that carry no
  per-file stat override (upstream #1451, `v0.6.15`). They travel on the wire as
  the core's `override_uid`/`override_gid` and mirror the Python SDK's public
  `uid:`/`gid:` spelling. Validation matches the Python SDK: the pair must be
  given together, each must be a plain `Integer` in `0..4294967295` (strings,
  Floats and Booleans are rejected rather than coerced — a truncated or parsed
  owner ID is never what the caller meant), and they conflict with both
  `stat_virtualization: :off` (no overlay to rewrite the owner in) and
  tmpfs/disk mounts. The one Python rule with no Ruby counterpart is
  "unsupported for disk-backed named volumes": a Ruby `{ named: "vol" }` spec
  only references an existing volume by name, so the volume's kind is known
  only to the core, which rejects that combination at create time.

### Changed

- Upstream runtime highlights carried without further Ruby surface:
  - `v0.6.15` — read-only mounts no longer fail a write probe at mount time,
    Windows DNS/NTFS handling, and the mount-ownership core work above.

## [0.15.0] - 2026-08-24

Adopts upstream runtime **`v0.6.9` → `v0.6.14`**, stepping through every
intermediate tag (v0.6.10, v0.6.11, v0.6.12, v0.6.13 each verified and
committed individually).

### Added

- `ssh.open_client` and `ssh.prepare_server` accept `inactivity_timeout:` —
  a per-session SSH inactivity timeout in seconds (upstream #1341, `v0.6.10`).
  `nil` (the default) inherits the global config (600s out of the box), `0`
  disables the timeout, and a negative or non-finite value raises
  `ArgumentError`, matching the Python binding's `ValueError` semantics. The
  SSH inactivity timeout stays separate from the sandbox lifecycle
  `idle_timeout`.

### Changed

- Upstream runtime highlights carried without further Ruby surface:
  - `v0.6.10` — bind-mount correctness (contained rootfs patches, parent-first
    nested destinations, path formatting), guest bootstrap moved off the kernel
    command line, DNS pins required for deferred domain allows, host-loopback
    family fallback, configurable global ssh inactivity timeout.
  - `v0.6.11` / `v0.6.12` — release-pipeline fixes (Linux glibc baseline
    lowered to 2.28; bundled `msb` executable mode preserved), reflected in the
    prebuilt bundles the companion binaries gem vendors.
  - `v0.6.13` — legacy ext4 upper-disk resize support; temporary exec
    sandboxes stopped on errors; `LocalBackendBuilder::try_build_lazy()` added
    upstream (embedding-host API — not adopted here, matching the Python
    binding; the ext stays on `LocalBackend::lazy()`).
  - `v0.6.14` — `msb_krun` VMM stack bumped to 0.1.32.

## [0.14.0] - 2026-08-24

Runtime tag unchanged — still upstream **`v0.6.9`**.

### Added

- **Companion gem `microsandbox-rb-binaries`** (source in `binaries/`): the
  prebuilt `msb` microVM runtime and the `libkrunfw` firmware, shipped as one
  gem per platform (`arm64-darwin`, `x86_64-linux-gnu`, `aarch64-linux-gnu`;
  the Linux binaries are glibc-linked, hence `required_rubygems_version >=
  3.3.11`). Install it alongside `microsandbox-rb` at the same version and your
  bundle carries the runtime instead of downloading it into `~/.microsandbox`
  on first use. There is no dependency edge in either direction — RubyGems has
  no optional dependencies, and cloud-only users should not be made to fetch
  ~50 MB of binaries. Motivated by upstream
  [superradcompany/microsandbox#1305](https://github.com/superradcompany/microsandbox/issues/1305).
- **A new tier in the runtime resolver.** `require "microsandbox"` activates the
  companion gem (if installed at the same version and built for the same
  upstream runtime) and hands
  its `msb` to the core's set-once SDK slot; the firmware is found by the
  runtime's `../lib` adjacency, exactly as in the Python/Node SDKs. The
  effective order is now `MSB_PATH` → `microsandbox-rb-binaries` → config file →
  `~/.microsandbox/bin/msb` → `msb` on `PATH`, and
  `Microsandbox.runtime_path` reports the winner. Activation never raises: a
  missing gem is silent, and a gem built for a *different* runtime is reported
  with a warning and skipped rather than handed to the core.
- **Lock-step guard for the new gem.** `Microsandbox::Binaries::VERSION` must
  equal `Microsandbox::VERSION` and `Microsandbox::Binaries::RUNTIME_VERSION`
  must equal `Microsandbox::RUNTIME_VERSION`; `spec/unit/version_spec.rb`
  asserts both, so a stale companion can't ship.
- **Vendoring/build pipeline** for the companion gem:
  `rake -C binaries vendor[<platform>]` downloads the upstream release bundle and
  verifies every file against that release's `checksums.sha256` as committed
  in `binaries/checksums/<tag>.sha256` (fail-closed — a missing entry, a digest
  mismatch, an unexpected file, or a live release file that disagrees with the
  committed one aborts), `rake -C binaries build[<platform>]` re-verifies the staged tree
  against its manifest before packaging, `rake -C binaries verify` runs the
  vendored `msb` on the host, and `vendor:all` covers every platform from any
  host. CI builds all three platform gems on every run, and `release.yml`
  builds and publishes them on each version tag in a separate
  `publish-binaries` job that runs after the SDK gem is live (a companion-gem
  failure is its own red job and never blocks the SDK release; re-runs are
  idempotent). The companion gem has its own RubyGems trusted-publisher entry.

### Changed

- **The SDK gem is now SDK-only: nothing is provisioned at build or install
  time.** The core crate's default `prebuilt` feature — whose `build.rs`
  downloaded the *host* runtime into `~/.microsandbox` while compiling the
  extension — is off (`default-features = false`, features `keyring`, `net`,
  `ssh`, matching the official SDKs). The *guest* agent `agentd` is still
  embedded into the extension at build time, via a direct
  `microsandbox-runtime` dependency with just the `prebuilt` sub-feature that
  fetches it. Host runtime provisioning is now the companion gem's job, with the
  first-use download as fallback.
- **`Microsandbox.runtime_path=` is a no-op when the companion gem is active** —
  it targets the same set-once slot the gem already claimed at load time. Use
  the `MSB_PATH` environment variable to override a bundled runtime.
- **`Microsandbox.ensure_runtime!` skips the installer entirely** when the
  resolved runtime is the companion gem's `msb`: those binaries are already the
  matching version, so nothing is downloaded or touched in `~/.microsandbox`.
  Without the gem, behaviour is unchanged — the version-correcting first-use
  download into `~/.microsandbox` remains the lowest tier, still opt-out-able
  with `MICROSANDBOX_NO_AUTO_INSTALL`.
- `Gemfile` now uses `gemspec glob: "{,*}.gemspec"` so Bundler resolves only the
  root gemspec; its default glob would also evaluate the nested
  `binaries/microsandbox-rb-binaries.gemspec` in every `bundle exec` process.

## [0.13.0] - 2026-08-18

Adopts upstream runtime **`v0.6.8` → `v0.6.9`**.

### Breaking

- **A bare `MSB_API_KEY` no longer selects the cloud backend** (upstream
  backend-selection hardening: "a bare API key is credential material, not
  backend intent"). Cloud intent must now be explicit: set `MSB_BACKEND=cloud`
  (with a non-empty `MSB_API_KEY`), select a cloud profile, or call
  `Microsandbox.set_default_backend(:cloud, ...)`. Code that relied on
  exporting only `MSB_API_KEY` now silently runs on the **local** backend —
  audit deployment environments when upgrading.
- **Invalid cloud configuration fails closed** instead of silently falling
  back to local execution: `MSB_BACKEND=cloud` without a usable API key or
  cloud profile raises {Microsandbox::InvalidConfigError} at first use rather
  than dispatching sandboxes locally.
- **Snapshot payload integrity is opt-in** (upstream #1346). New snapshots no
  longer record a content digest unless created with
  `record_integrity: true` (previously documented as a no-op because schema-1
  always recorded integrity — that default reversed upstream, as hashing
  large allocated uppers is expensive). {Microsandbox::Snapshot.verify} on a
  snapshot without recorded integrity now reports
  `SnapshotVerifyReport#status == :not_recorded` (with `#algorithm` /
  `#content_digest` nil, `#verified?` false) instead of always `:verified`.

### Added

`v0.6.9` SDK parity (matching the official Python binding surface):

- **Default-workload execution** — `Sandbox.create` is strictly boot-only, so
  the image's resolved OCI `ENTRYPOINT`+`CMD` now runs via
  {Microsandbox::Sandbox#exec_default} (buffered),
  {Microsandbox::Sandbox#exec_default_stream} (streaming), and
  {Microsandbox::Sandbox#attach_default} (interactive). New
  {Microsandbox::NoDefaultCommandError} when the image resolves no executable
  command. New `cmd:` create keyword overrides the durable image CMD (an
  explicit `[]` clears it) without executing anything at create time.
- **Flat OCI root disks** — `RootDisk.flat(size_mib, fstype:, clone:)` boots
  from a single complete ext4 root disk materialized from the OCI image
  (skips the overlay stack; content-addressed and cached; `clone:` picks
  `:auto`/`:copy`/`:reflink` private-disk cloning).
- **Root-disk resizing** — `modify(root_disk_size:)` grows the managed upper
  or flat root disk (MiB).
- **Per-sandbox network rate limits** — `rate_limiter:` create keyword with
  per-direction (`egress:`/`ingress:`) `bandwidth:`/`ops:` token buckets
  (`size:`, `refill_time_ms:`, `one_time_burst:`).
- **Host vsock routes** — `vsock:` create keyword exposes host Unix sockets
  on guest-to-host vsock ports: `{ "/host/api.sock" => 5000 }` or an Array of
  `{host_socket:, port:, socket_type: :stream|:dgram}`.
- **Active backend context** — {Microsandbox.default_backend_info} returns a
  secret-safe {Microsandbox::BackendInfo} (`kind`, `api_url`, `source`,
  `profile`; never the API key).
- **Default volume** — {Microsandbox::Volume.get_default} (cloud backend;
  local raises {Microsandbox::UnsupportedError}) and
  `VolumeInfo#default?`. The full `VolumeInfo#fs` surface works against cloud
  default and managed directory volumes as of `v0.6.9`.

Not exposed, matching the official Python binding at `v0.6.9`:
`DeploymentProfile`/CPU-placement/THP create options (upstream wires them via
`config.json`/CLI only so far) and the Rust-only sparse
`SandboxConfigPatch`/`builder.configure` surface.

### Fixed

- `entrypoint: []` now clears the image's `ENTRYPOINT` (blocking the
  image-config merge), matching the upstream builder contract and the Python
  binding. Previously the empty array was silently dropped in the native
  layer, so the image ENTRYPOINT survived — observable under the new
  `exec_default`/`attach_default`, which would have run the wrong command.
  `nil` (the default) still inherits the image value.

### Runtime

- Upstream `v0.6.9` runtime changes carried without further Ruby surface
  change: NUMA-aware placement profiles, degraded placement under pressure,
  integrated host performance stack (topology-aware CPU placement, THP
  policy, bounded block writeback), long-link-target preservation in saved
  image archives, nested OCI image index loads, backpressured published-port
  data preservation, DNS network-rule parsing in release builds, and
  child-process reaping in `agentd`.

## [0.12.0] - 2026-07-30

Adopts upstream runtime **`v0.6.7` → `v0.6.8`** and mirrors its breaking SDK
surface (upstream #1232 "unify cloud backend and paginated listings"), keeping
parity with the Python/Node SDKs.

### Breaking

- **Sandbox listing is cursor-paginated** (upstream #1232). `Sandbox.list` and
  `Sandbox.list_with` now return a {Microsandbox::SandboxPage} — an Enumerable
  page of `SandboxHandle`s carrying `#next_cursor` — instead of a plain Array.
  `Sandbox.list` fetches the first page (upstream default size 20);
  `Sandbox.list_with` gains `limit:` (1..100) and `cursor:` keywords alongside
  the existing `labels:` filter. Code that only enumerates
  (`list.each`/`map`/`to_a`) keeps working; code relying on the return value
  *being* an Array (e.g. `list + other`, `Array ===`) must adapt, and listings
  of more than one page must follow `page.next_cursor` via
  `list_with(cursor:)`.
- **`UnsupportedError` messages are re-keyed by structured operations**
  (upstream #1232): the core now reports the rejected API and a remedial hint
  (e.g. `image.list is not supported by this backend: use a local backend`)
  instead of the old free-text `feature`/`available_when` pair. The exception
  additionally exposes the new structured attributes below.

### Added

- {Microsandbox::SandboxPage} — Enumerable over its `#sandboxes`, plus
  `#next_cursor`, `#size`/`#length`, `#empty?` and `#last_page?`.
- `Sandbox.list_with(labels:, limit:, cursor:)` pagination keywords.
- `UnsupportedError#operation` / `#hint` — the rejected API in Ruby rendering
  (`"sandbox.kill"`) and the remedial hint (`"use a local backend"`),
  mirroring the Python SDK's enriched `UnsupportedError`.

### Changed

- Direct `VolumeFs` operations now route through the backend's volume trait
  (upstream #1232) instead of a construction-time local-backend guard, so an
  unsupported backend rejects each operation with a precise per-operation
  error.
- The embedded runtime is `v0.6.8`; see the upstream release notes for
  runtime-side changes (shared log registry for followed streams, cloud
  sandbox reconnect fixes for `exec`/`ssh`, kernel sourced from
  cdn.kernel.org).

## [0.11.0] - 2026-07-27

Adopts upstream runtime **`v0.6.6` → `v0.6.7`** and mirrors its breaking SDK
surface, keeping parity with the Python/Node SDKs (which ship the same renames
without compatibility aliases). The bundled runtime also carries the fix for
**GHSA-4vq3-cjpp-v7fg** (`msb copy` symlink traversal: a sandboxed workload
could make a later CLI copy-out overwrite an arbitrary host file — the SDK
`fs`/`copy_to_host` paths were not affected).

### Breaking

- **Network presets `public_only`/`non_local` are removed** (upstream #1198),
  replaced by composable **profiles** `:public` / `:private` / `:host`:
  `network: [:public, :private]`, single-profile sugar `network: :public`, or
  `NetworkPolicy.from_profiles(:public, :host)`. Any non-empty profile set
  automatically allows gateway DNS. The replacements are rule-for-rule
  equivalent (`public_only` ≡ `[:public]`, which is still the default policy;
  `non_local` ≡ `[:public, :private]`); the removed spellings (and
  `NetworkPolicy.public_only`/`.non_local`) now raise an `ArgumentError` with
  that migration guidance. `network: :none`/`:allow_all` (and their aliases)
  and `network: :default` keep working unchanged. In the Hash form,
  `profiles:` composes with `rules:`/`default_egress:`/`default_ingress:`/deny
  lists; explicit `rules:` are evaluated **before** the profile expansion
  (matching the upstream CLI), so a narrower override such as
  `Rule.deny_dns` wins over a profile's allows under first-match-wins.
- **`Snapshot.create` is re-keyed by the snapshot's own name** (upstream
  #1118): `Snapshot.create(name, from_sandbox:, dest_dir:, labels:, force:,
  record_integrity:, resumable:)` — the positional argument is now the
  snapshot name (was: the source sandbox), `from_sandbox:` is required, and
  `path:` is replaced by `dest_dir:`, a **parent directory** (the artifact
  always lands at `dest_dir/<name>`). `record_integrity:` is now a no-op
  (schema-1 descriptors always record integrity); `resumable:` is accepted and
  raises `UnsupportedError` until VM pause/resume lands upstream.
- **`Snapshot.export`/`Snapshot.import` are renamed `Snapshot.save`/
  `Snapshot.load`** (same parameters), matching the Python/Node rename.
- **`SandboxHandle#snapshot_to` is removed** (deleted upstream). Use
  `Snapshot.create(name, from_sandbox: handle_name, dest_dir: dir)` for
  explicit placement.
- **`SnapshotVerifyReport#not_recorded?` is removed** and `#status` is always
  `:verified`: integrity is now mandatory at snapshot-create time, so the
  "not recorded" outcome no longer exists (a mismatch raises
  `SnapshotIntegrityError` as before).
- **`SnapshotInfo#size_bytes`/`#format`/`#fstype` are now nilable** — nil for
  the new checkpoint-state snapshots (file-state snapshots, the only kind
  producible today, still populate all three).

### Added

- **Structured root disk** (upstream #1165) — `Sandbox.create(root_disk:)`
  configures the OCI sandbox's writable layer: an Integer (managed ext4 upper
  size cap in MiB, the old `oci_upper_size:` meaning), or a `RootDisk` factory
  Hash: `RootDisk.managed(8192)`, `RootDisk.tmpfs(2048)` (RAM-backed, pristine
  rootfs on every boot; size ≤ sandbox memory; not snapshot/patchable), or
  `RootDisk.disk("./scratch.img", format:, fstype:)` (user-supplied image
  attached writable; never created/resized/deleted by the runtime).
  `oci_upper_size:` remains as a deprecated alias (warns; conflicts with
  `root_disk:`).
- **`Image.load` / `Image.save`** (upstream #1151/#1174) — move OCI images in
  and out of the local cache as `docker save`-style or OCI Image Layout
  archives: `Image.load("./app.tar", tag: "app:dev")` (pass `"-"` to read
  stdin; returns the loaded `ImageInfo`s) and
  `Image.save("alpine:latest", output_path: "./alpine.tar", format: :docker)`.
- **`Rule.allow_dns` / `Rule.deny_dns`** — the gateway-DNS rule pair the
  profiles expand to (egress → group `:host`, udp+tcp, port 53), for use in
  custom policies (`deny_dns` upstream #1198).
- **Snapshot descriptor metadata** on `SnapshotInfo`: `#scope` (`:disk` /
  `:resumable`), `#state_kind` (`"file"`/`"checkpoint"`), `#checkpoint_id`,
  `#checkpoint_manifest_digest`, and the index columns `#locality`,
  `#availability`, `#migration_state`, `#migration_error_code`.
- **`SnapshotMigrationError`** — raised when the automatic v0.6.6→v0.6.7
  snapshot-descriptor migration is blocked and needs repair (new core
  `SnapshotMigration` variant, upstream #1200).
- **`follow_root_symlinks:` volume flag** — per-mount opt-out of the runtime's
  new default-on mount-root symlink protection (upstream #1149; bind/named
  mounts only). The Rust SDK exposes the same switch; Python/Node defer it.

### Changed

- **Snapshot artifacts migrate on first use** (upstream #1200): the runtime
  rewrites each v0.6.6 `manifest.json` descriptor to the v0.6.7
  `snapshot.json` (keeping the old file as `.manifest.json.legacy`) at backend
  connect, after which gems ≤ 0.10.x can no longer read those artifacts —
  rolling back requires the upstream `msb self downgrade` tooling.
- **Bind/named mount roots refuse symlinked roots by default** (upstream
  #1149) — opt out per mount with `follow_root_symlinks: true`.
- **DNS rebind protection is fail-closed for unspecified addresses** (upstream
  #1198): `0.0.0.0`/`::` no longer classify as `public`, so a `public`-profile
  sandbox can't be steered to them via DNS answers.
- `ModificationPlan` change/conflict entries for the managed upper now report
  `field: "root_disk_size"` (was `"oci_upper_size"`) — the runtime's canonical
  field name, passed through verbatim as always.
- Duplicate secret placeholders across secret entries are now allowed
  (upstream #1178); snapshotting a tmpfs or disk-image root disk fails with a
  purposeful `InvalidConfigError` (upstream #1169).

## [0.10.0] - 2026-07-09

Ruby bindings for the additive `v0.6.6` SDK surface (upstream #1099 / #1128),
bringing the gem to parity with the Python and Node SDKs, which already ship
this API. The embedded runtime tag is unchanged (`v0.6.6`); this is a pure
binding addition with no breaking change.

### Added

- **Live sandbox modification** — `Sandbox#modify` and `SandboxHandle#modify`
  plan or apply a change to a running (or stopped) sandbox without recreating
  it: resize CPU/memory (`cpus:`, `max_cpus:`, `memory:`, `max_memory:`, MiB),
  adjust `env:`/`remove_env:`, `labels:`/`remove_labels:`, and `workdir:`, and
  rotate/remove secrets (`secrets:` keyed by name with mutually-exclusive
  `env:`/`store:`/`value:` plus `placeholder:`/`allowed_hosts:`,
  `remove_secrets:`). `policy:` selects `:no_restart` (default), `:next_start`,
  or `:restart`; `dry_run: true` computes the plan without applying it. Returns
  a typed `ModificationPlan` (`#sandbox`, `#status`, `#applied?`, `#policy`,
  `#changes`, `#conflicts`, `#warnings`, `#resize_status`) whose nested entries
  are frozen, symbol-keyed Hashes carrying the runtime's canonical snake_case
  fields verbatim.
- **Health checks** — `Sandbox#ping` / `SandboxHandle#ping` return a
  `PingResult` (`#name`, `#latency` in seconds, `#latency_ms`) confirming the
  guest agent is reachable **without** refreshing the idle timer; `#touch`
  returns a `TouchResult` (`#name`, `#activity_seq`) that explicitly refreshes
  the idle-activity timer. On the handle, both raise `SandboxNotRunningError`
  for a stopped sandbox (it is not started implicitly).
- **Create-time resource ceilings** — `Sandbox.create` accepts `max_cpus:` and
  `max_memory:` (MiB), the boot-time maxima a later live `modify` can grow up
  to (each defaults to its `cpus:`/`memory:` value and must be >= it).
- **`SandboxNotRunningError`** is now raised by the runtime's not-running guard
  (the class already existed; the new core `SandboxNotRunning` variant is now
  mapped to it instead of falling back to the base `Error`).

Deliberately **not** exposed, matching the Python and Node SDKs (both surface
these only through the CLI): `modify`'s `oci_upper_size` overlay-grow field, and
the `SandboxMetricsReport` / per-sandbox metrics-report helpers.

## [0.9.3] - 2026-07-09

Adopts upstream runtime **`v0.6.3` → `v0.6.6`** (spanning upstream `v0.6.4` and
`v0.6.6`; `v0.6.5` was yanked upstream — its GitHub release was pulled and the
type-model refactor it shipped, #1014, was reverted in `v0.6.6`, #1143). The
upstream SDK crate's public API grew only *additive* surface (live
modify/resize, ping/touch — Ruby bindings for these land in the next minor),
so this is a pure runtime bump with no Ruby API change.

### Fixed

- **Snapshot restore survives upstream tag republishes** (upstream #1130):
  restore now pulls the OCI image by its pinned manifest digest
  (`<repo>@sha256:…`) instead of re-resolving the mutable tag, fixing a fatal
  `v0.6.3` regression where a republished base-image tag made existing
  snapshots unrestorable.
- **Fragmented UDP and PMTU relay traffic is forwarded correctly** (upstream
  #1086) by the sandbox network relay.
- **`exec` termination kills the whole process group, not just the direct
  child** (upstream #1104): guest commands that spawn children (e.g. shell
  pipelines) no longer leave orphaned grandchildren running after a kill.
- **Stop waits tolerate ephemeral cleanup** (upstream #1087, inherited in
  `Sandbox#stop`/`SandboxHandle#wait_until_stopped`): if an ephemeral
  sandbox's persisted state is cleaned up while a stop wait is in flight, the
  wait now resolves to a synthetic `stopped` result instead of raising
  `SandboxNotFoundError`. Persistent sandboxes are unaffected.
- **Filesystem snapshot `readdir` streams entries** (upstream #1133), fixing
  unbounded memory growth (RSS leak) when listing very large directories.

### Changed

- **Embedded runtime is now `v0.6.6`** (`Microsandbox::RUNTIME_VERSION` /
  `Microsandbox.runtime_version`). Also inherited:
  - `Sandbox.create`/`.start` persist an active-config snapshot of the booted
    sandbox in the runtime database (upstream SDK behavior; groundwork for
    live modification).
  - The runtime's shutdown flush timeout can be overridden via the
    `MSB_SHUTDOWN_FLUSH_TIMEOUT_MS` environment variable (upstream #1088).
  - The prebuilt `msb` binary gains `modify`/`ping`/`restart`/`touch`
    subcommands and `metrics --watch`; these are CLI-level for now — the
    corresponding Ruby APIs (`#modify`, `#ping`, `#touch`) ship in the next
    minor release.

## [0.9.2] - 2026-07-08

Adopts upstream runtime **`v0.6.2` → `v0.6.3`**. No Ruby API change; the
native glue moves to the explicit-backend variants of a few SDK calls that
went "ambient config" upstream (#1091).

### Fixed

- **DNS no longer advertises unreachable address families to the guest**
  (upstream #1083): on hosts without a working IPv6 route the sandbox is
  IPv4-only, but the DNS forwarder previously still returned real AAAA
  records, so v6-preferring resolvers inside the guest (gRPC/c-ares
  foremost) tried IPv6 first and failed with unreachable-network errors.
  AAAA queries in a v4-only sandbox (and A queries in a v6-only one) now
  synthesize an empty NOERROR answer, steering guests to the usable family.
  Also normalizes IPv4-mapped IPv6 addresses for policy/rebind/resolved-
  hostname checks.

### Changed

- **Embedded runtime is now `v0.6.3`** (`Microsandbox::RUNTIME_VERSION` /
  `Microsandbox.runtime_version`). Also inherited: upstream TLS interception
  scopes upstream-certificate verification per destination (#1073).
- Native glue adapted to the upstream v0.6.3 SDK surface (#1091 restored
  "ambient local config" as the public shape): `Image.get/list/inspect/
  remove/prune` and `all_sandbox_metrics` now call the explicit
  `*_local(backend, …)` variants, and the resolved-`msb`-path probe uses the
  `LocalConfig#resolve_msb_path` method form. Behavior is identical — the
  gem already held an explicit local backend at every call site.

## [0.9.1] - 2026-07-03

Adopts upstream runtime **`v0.6.1` → `v0.6.2`**. The upstream SDK crate's public
API is unchanged in this release — the only surface change attempted upstream (a
`disk_size` builder rename, #983) was reverted before the release cut (#1078) —
so this is a pure runtime bump with no Ruby API change.

### Changed

- **Embedded runtime is now `v0.6.2`** (`Microsandbox::RUNTIME_VERSION` /
  `Microsandbox.runtime_version`). Upstream improvements inherited by the gem:
  - **Faster image loads and pulls** (upstream #1075): an early cache gate skips
    already-imported layers and OCI layer decompression switches to zlib-rs.
    Inherited transitively through the SDK crate's `microsandbox-image`
    dependency, so `Sandbox.create` image pulls benefit directly.
  - `msb` CLI polish (terminal-aware help colors, aligned `doctor` runtime
    diagnostics, image-load progress) ships in the prebuilt runtime binary but
    does not affect the Ruby API surface.

## [0.9.0] - 2026-06-29

Adopts upstream runtime **`v0.5.10` → `v0.6.1`** (spanning the upstream `v0.6.0`
and `v0.6.1` releases). The upstream public SDK surface is purely additive — no
items were removed or re-signatured — so the gem's Ruby API is unchanged and the
existing bindings compile against `v0.6.1` untouched. Per the README's versioning
policy, adopting a new upstream runtime moves the gem onto its own `0.9` line.

### Changed

- **Embedded runtime is now `v0.6.1`** (`Microsandbox::RUNTIME_VERSION` /
  `Microsandbox.runtime_version`). Upstream fixes inherited by the synchronous
  Ruby API:
  - **Zombie sandbox runtimes no longer block** (upstream #1036): the SDK stops
    waiting on a sandbox runtime that has already exited, so lifecycle calls
    return promptly instead of hanging on a dead child.
  - **Secrets are substituted through `CONNECT` proxies** (upstream #1022):
    `microsandbox-network` now applies secret injection on tunnelled (HTTPS
    `CONNECT`) requests, not only on plain-HTTP ones.
  - **Stale sandboxes are stopped and cleaned up** (upstream #1050).
  - Windows host support, `msb` CLI additions (`--no-tty`, self-downgrade,
    cross-platform `doctor`), and the `msb_krun` `0.1.17 → 0.1.19` bump are
    inherited but do not affect the macOS/Linux Ruby build or API surface.

### Notes

- The new upstream **host-directory bind rootfs** (`ImageBuilder::bind`, upstream
  #1021) is intentionally **not** exposed in this release: it requires a real
  microVM boot to exercise, and the Python SDK parity reference only stubs the
  type without wiring it into the sandbox builder. Tracked as a possible
  follow-up.

## [0.8.2] - 2026-06-29

Gem-only release on the `v0.5.10` runtime (unchanged). Bundles the post-`0.8.1`
audit follow-ups: a secret-leak fix, typed snapshot errors, panic-free duration
parsing, the precompiled fat-gem loader + `extconf` preflight corrections, and a
sweep of threading/streaming/SSH documentation.

### Documentation

- **Calling-thread non-preemption is now documented** (issue #24). The GVL is
  released during native calls so *other* threads keep running, but the
  *calling* thread blocks uninterruptibly until the call returns —
  `Timeout::timeout`/`Thread#kill`/Ctrl-C can't interrupt it. README and
  DESIGN.md now state this and steer callers to the genuinely-bounding
  `exec(timeout:)` / `shell(timeout:)` knobs, and clarify that
  `AgentClient.connect_sandbox`/`connect_path`'s `timeout:` bounds only the
  connect handshake while `AgentClient#request`/`#stream` and the streaming
  paths have no timeout knob and can block indefinitely — rather than reaching
  for `Timeout::timeout`.
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
- **RBS gains a note on SDK-constructed types** (issue #36). `sig/microsandbox.rbs`
  now carries a top-of-file note explaining that native-backed value/handle/stream
  types are constructed by the SDK from an internal native handle or data hash, not
  by user code. Their `initialize` signatures are kept: RBS derives `new` from
  `initialize`, so omitting them would not hide the constructor — it would
  synthesize a misleading zero-arg `() -> instance` that Ruby actually rejects.

### Fixed

- **Precompiled fat-gem loader now finds the staged binary** (issue #25). The
  native-extension require used `RbConfig::CONFIG["ruby_version"]` — the API
  string `"3.4.0"` — but rake-compiler stages a multi-version fat gem's binaries
  under the **major.minor** subdir (`3.4`), so the versioned require always
  missed and fell to the flat-path rescue, which is **absent** in a precompiled
  gem (only the versioned binary is packed). Every fat-gem install would have
  failed at `require "microsandbox"` the moment precompiled gems are promoted.
  The loader now derives the subdir from `RUBY_VERSION[/\d+\.\d+/]` (`"3.4"`),
  matching the staged path; the flat-path rescue still covers source builds.
- **`extconf` MSRV preflight probes the compiler the build actually runs**
  (issue #39). The preflight ran a bare `rustc --version` and hard-aborted when
  `< 1.91`, but the build is driven by `cargo`, which resolves its compiler from
  `$RUSTC` if set, otherwise the bare `rustc` on PATH — it never uses the `rustc`
  beside the `cargo` binary, and the rustup `cargo` shim neither sets `$RUSTC` nor
  reorders PATH. The preflight now mirrors that exact resolution (`$RUSTC`, else
  PATH `rustc`), so it neither false-passes when a stale non-rustup `rustc`
  shadows a rustup `cargo` (the build would compile with that stale `rustc` and
  fail deep in smoltcp) nor false-aborts when `$RUSTC` points at a newer compiler.

### Internal

- **CI now installs the packed gem from source** (issue #37). A new `package`
  job runs `rake build`, `gem install`s the packed gem (exercising the gemspec
  `spec.files` glob and the full from-gem `extconf` + `cargo` compile against the
  packed `Cargo.toml`/`Cargo.lock`/`rust-toolchain.toml`), and requires it from
  outside the repo. Previously every job compiled the working tree in place, so
  a packaging regression could reach RubyGems undetected.
- **`version_spec` now guards the `Cargo.lock` version** (issue #38). The spec
  already asserted `Native.version == VERSION` and the runtime-tag pin, but
  nothing checked the `microsandbox_rb` version in the committed `Cargo.lock`,
  which the gemspec packs. A release that bumped `version.rb` + `Cargo.toml` but
  forgot to refresh the lock would ship a stale lock (and a `--locked` build
  would reject it) — a recurring release mistake this now catches.
### Security

- **Secret values no longer leak into `ArgumentError` messages** (issue #23).
  `Sandbox.create(secrets:)` validation interpolated the whole secret spec via
  `spec.inspect` into two error messages — and because the `:value`-present
  guard runs first, the "needs `:host`/`:hosts`/`:host_patterns`" error *always*
  embedded the cleartext secret value (and the env/value error did whenever a
  value was supplied). Such messages routinely reach logs and error trackers.
  Both messages now report the spec's keys only (`spec.keys.inspect`), mirroring
  the existing `registry_auth` handling, with a unit spec asserting the value
  is never present in the raised message.

### Fixed

- **Native duration parsing is panic-free regardless of the Ruby layer**
  (issue #30). The native binding called `Duration::from_secs_f64` directly at
  five sites (`exec`/`shell` timeout, `stop_with_timeout`, `kill_with_timeout`,
  `metrics_stream` interval, `replace_with_timeout`); that panics on NaN/Inf/
  negative *and on finite-but-out-of-range* values (e.g. `Float::MAX`), which
  surfaced as an ugly panic-turned-exception. The Ruby `coerce_duration` guard
  set no upper bound, so a large finite value still reached and panicked the
  native layer. All five sites now route through a `secs_to_duration` helper
  (`try_from_secs_f64` + a clean `Microsandbox::Error`), matching the existing
  agent-client pattern — defense in depth so the native layer is panic-free on
  its own.
### Added

- **Typed snapshot error classes** (issue #28). The five core snapshot error
  variants — reachable through the gem's fully-wired `Snapshot` API — previously
  collapsed to the base `Microsandbox::Error`, forcing callers to string-match
  the message. They now raise typed subclasses:
  `SnapshotNotFoundError` (`snapshot-not-found`),
  `SnapshotAlreadyExistsError` (`snapshot-already-exists`),
  `SnapshotSandboxRunningError` (`snapshot-sandbox-running`),
  `SnapshotImageMissingError` (`snapshot-image-missing`), and
  `SnapshotIntegrityError` (`snapshot-integrity`). This goes **beyond** the
  Python SDK mirror (which defines no snapshot classes), matching the Go SDK's
  per-variant coverage — a deliberate divergence. Additionally, the previously
  orphaned `NetworkPolicyError` now also carries the core's `NetworkBuilder`
  build/validation error (a `network(|n| ...)` failure), which previously fell
  through to the base `Error`. All additive — existing `rescue Microsandbox::Error`
  handlers still catch them.

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

[Unreleased]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.14.0...HEAD
[0.14.0]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.13.0...v0.14.0
[0.9.0]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.8.2...v0.9.0
[0.8.2]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.12...v0.6.0
[0.5.12]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.11...v0.5.12
[0.5.11]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.10...v0.5.11
[0.5.10]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.9...v0.5.10
[0.5.9]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.8...v0.5.9
[0.5.8]: https://github.com/ya-luotao/microsandbox-rb/compare/v0.5.7...v0.5.8
[0.5.7]: https://github.com/superradcompany/microsandbox/releases/tag/v0.5.7
