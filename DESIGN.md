# microsandbox Ruby SDK — Architecture

This gem is the Ruby member of the official microsandbox SDK family. Like the
Python, Node, and Go SDKs, it does **not** talk to a daemon over a socket:
it embeds the microsandbox runtime directly in the host process through a Rust
native extension and spawns real microVMs as child processes.

## Why a native extension (not pure Ruby)

The official SDKs (`sdk/python`, `sdk/node-ts`, `sdk/go`) are all thin language
bindings over the same Rust core crate (`crates/microsandbox`):

| SDK     | Binding tech            | Artifact                |
|---------|-------------------------|-------------------------|
| Python  | pyo3                    | `_microsandbox` cdylib  |
| Node    | napi-rs                 | `.node` addon           |
| Go      | cgo + FFI header        | static lib              |
| **Ruby**| **magnus + rb-sys**     | **`microsandbox_rb.bundle`** |

There is no network protocol to reimplement in pure Ruby — the runtime is
embedded. So the only way to be *aligned* with the official SDKs is to wrap the
**same** `microsandbox` core crate. We use [magnus](https://github.com/matsadler/magnus)
(0.8) + [rb-sys](https://github.com/oxidize-rb/rb-sys) (0.9), the modern,
production-grade Ruby↔Rust toolchain (used by `wasmtime-rb`, `oxi-test`, etc.).

## Two layers (mirrors the Python SDK)

```
lib/microsandbox/*.rb      ← ergonomic, idiomatic Ruby (this is what users call)
        │ delegates to
ext/microsandbox/src/*.rs  ← magnus bindings over the core crate (Microsandbox::Native::*)
        │ calls
crates/microsandbox        ← the shared Rust runtime engine
```

* **Native layer** (`Microsandbox::Native`): thin, synchronous wrappers that own
  the core Rust objects (`Sandbox`, `ExecOutput`, `SandboxFsOps`, …) and expose
  primitive-typed methods. Mirrors `sdk/python/src/*.rs`.
* **Ruby layer** (`Microsandbox`): keyword-argument constructors, block-form
  lifecycle (`Sandbox.create(...) { |sb| ... }` auto-stops, like Python's
  `async with`), predicate/bang naming, the typed error hierarchy, and value
  objects. Mirrors `sdk/python/microsandbox/*.py`.

## Sync, not async

Ruby has no `async`/`await` in its core object model, so — like the **Go** SDK —
the Ruby API is **synchronous**. The core crate is async (tokio). Each native
method runs its future to completion on a shared, lazily-initialized
multi-threaded tokio runtime via `runtime.block_on(fut)`.

### GVL release

`block_on` is wrapped in `nogvl` (`rb_thread_call_without_gvl`) so the Ruby
Global VM Lock is **released** while a sandbox operation is in flight. Without
this, a long-running `exec` would freeze every other Ruby thread/fiber in the
process (a real problem under Rails/Puma). The `nogvl` closure runs pure Rust
only (never touches the Ruby C API) and uses `catch_unwind` so a Rust panic is
captured and re-raised *after* the GVL is re-acquired rather than unwinding
across the C frame (which would be UB).

**The *calling* thread is not preemptible during the call.** `nogvl` passes a
null unblock-function to `rb_thread_call_without_gvl`, and Ruby only checks
pending interrupts *before* and *after* the GVL-released region — so while a
native call blocks, the thread that issued it cannot be interrupted:
`Timeout::timeout` (which relies on `Thread#raise`), `Thread#kill`, and `SIGINT`
(Ctrl-C) are all deferred until the call returns on its own. The GVL release
keeps *other* threads live; it does **not** make the calling thread
cancelable. This is harmless for the bounded calls (`exec`/`shell` with a
`timeout:`, `AgentClient` with a `timeout:`) because the deadline fires inside
the future, but the unbounded/streaming paths — `exec`/`shell` with
`timeout: nil`, `ExecHandle#recv`/`#wait`, `log_stream`/`metrics_stream` `recv`
(especially `follow: true`), `Sandbox#wait`/`SandboxHandle#wait_until_stopped`,
and `AgentClient#request` with no timeout — can block their caller indefinitely
if the guest wedges or a relay drops. **Bound such calls with the explicit
`timeout:` knobs rather than wrapping them in `Timeout::timeout`**, which will
not fire while the native call is in flight.

## Error mapping

The core returns one big `MicrosandboxError` enum. `error.rs` maps each variant
to a Ruby exception class under `Microsandbox` (e.g. `InvalidConfig` →
`Microsandbox::InvalidConfigError`), all descending from `Microsandbox::Error`,
each carrying a stable `#code`. This mirrors `sdk/python/microsandbox/errors.py`
and the Rust→class mapping in `sdk/python/src/error.rs`.

## Runtime binary (`msb` + `libkrunfw`)

The core crate's `prebuilt` feature (on by default) downloads the `msb` microVM
runtime and `libkrunfw` firmware into `~/.microsandbox/{bin,lib}` **at build
time** (`build.rs`). The path resolver checks, in order: `$MSB_PATH` →
SDK-set path (`Microsandbox.runtime_path=`) → config file → workspace build →
`~/.microsandbox/bin/msb` → `which msb`. `Microsandbox.install` / `.installed?`
expose the core `setup::install`/`is_installed` for explicit, idempotent
provisioning (mirrors the Python `install()`/`is_installed()`).

Build-time provisioning only helps the **source gem**, where `build.rs` runs on
the user's own machine. A **precompiled gem** is built in CI, so its build-time
download lands on the CI host, not the user's — the user's `~/.microsandbox` is
empty. `Microsandbox.ensure_runtime!` closes that gap: `Sandbox.create`/`start`
call it to fetch the runtime on first use (by the *running* host's arch, which is
always correct), at most once per process. `MICROSANDBOX_NO_AUTO_INSTALL` opts
out (air-gapped hosts that provision out of band). libkrunfw is `dlopen`'d by
`msb` at runtime and is never linked into the extension.

## Core-crate dependency (self-contained)

`ext/microsandbox/Cargo.toml` depends on the core crate via a **pinned git tag**
(`microsandbox` / `microsandbox-network`, pinned to the same tag as
`Microsandbox::RUNTIME_VERSION` — currently `v0.6.1`), so the gem builds anywhere
— CI, `rake-compiler-dock` release containers, and end-user source installs —
without an adjacent checkout. For fast local development against a sibling
microsandbox checkout, copy `.cargo/config.toml.example` to `.cargo/config.toml`
(gitignored); its `paths` override builds against the local crates instead of
git. The override must never be committed — it would break container builds.

## Packaging & releases

* **Source gem**: compiles the extension via `extconf.rb` (rb-sys
  `create_rust_makefile`); requires a Rust toolchain (MSRV below).
* **Precompiled platform gems**: built best-effort by the `cross-gems` job
  (`.github/workflows/release.yml`) with `oxidize-rb/cross-gem-action`
  (`rake-compiler-dock`) per `Gem::Platform`, shipping multi-ABI
  `lib/microsandbox/<ruby_abi>/` native artifacts — the same model Node uses with
  per-platform packages. End users then install with no Rust toolchain, and the
  runtime is fetched on first use (see above). The guest `agentd` is baked into
  the extension by *target* arch (`filesystem/build.rs` uses
  `CARGO_CFG_TARGET_ARCH` + `include_bytes!`), so it cross-compiles correctly;
  the real cross work is linking the *target* native libs — `libcap-ng` on Linux
  (via Debian multiarch for `aarch64-linux`) and the Hypervisor + Security
  frameworks on macOS (via osxcross; `arm64-darwin` is the platform still to
  confirm — if osxcross can't link them, move it to a native `macos-14` runner).
  The job is gated to `workflow_dispatch` and **not** auto-published on tags:
  since CI can't boot a microVM to prove a built gem actually works, gems are
  promoted to the publish path manually after per-platform validation. Published
  to RubyGems via Trusted Publishing (OIDC). See [Releasing](README.md#releasing).

## Build requirements

* Ruby >= 3.1, RubyGems >= 3.3.11
* Rust (stable) >= 1.91 — the core crate is edition 2024 and pulls `smoltcp`
  which sets MSRV 1.91. `rust-toolchain.toml` pins `stable`.
* Linux with KVM, or macOS on Apple Silicon (same as the other SDKs).

## Implemented surface (v1) vs roadmap

**Implemented:** sandbox lifecycle (`create`/`start`/`get`/`list`/`list_with`/
`remove`; the live `Sandbox` exposes `stop`/`stop_and_wait`/`kill`/`drain`/
`wait` (→ `ExitStatus`) / `status` / `detach` / `owns_lifecycle?`, while the
controllable `SandboxHandle` from `get`/`list` carries the fine-grained
`stop_with_timeout`/`request_stop`/`request_kill`/`request_drain`/
`wait_until_stopped` (→ `SandboxStopResult`) controls — the v0.5.8 live-vs-handle
split that mirrors the official SDKs), backend routing (`set_default_backend`/
`with_backend`/`default_backend_kind`), block form), `exec`/`shell` with collected `ExecOutput`,
**streaming** `exec_stream`/`shell_stream` (`ExecHandle` is `Enumerable` over
`ExecEvent`s, with stdin sink + signal/kill/resize), the full guest filesystem
API (`fs.read`/`write`/`list`/`mkdir`/`remove`/`stat`/…), `metrics`,
`Microsandbox.all_sandbox_metrics`, **streaming `metrics_stream`/`log_stream`**
(`Enumerable` over `Metrics`/`LogEntry`), `logs`,
**OCI image-cache management** (`Image.get`/`list`/`inspect`/`remove`/`prune`),
**named volumes** (`Volume.create`/`get`/`list`/`remove` + `volumes:` mounts),
**snapshots** (`Snapshot.create`/`get`/`list`/`remove`/`verify`/`export`/`import`
+ `from_snapshot:` boot), **rootfs patches** (`Patch.text`/`file`/`append`/
`copy_file`/`copy_dir`/`symlink`/`mkdir`/`remove` via `create(patches:)`),
**custom per-rule network policies** (`NetworkPolicy`/`Rule`/`Destination` —
CIDR/IP/domain/suffix/group allow-deny rules with per-direction defaults and
bulk domain denials, alongside the presets), interactive **`attach`/
`attach_shell`** (host-TTY coupled — raw mode + SIGWINCH), **SSH**
(`Sandbox#ssh` → `SshClient`/`SftpClient`/`SshServer`), the **raw agent client**
(`AgentClient` → `AgentStream`/`AgentFrame`),
`version`/`install`/`installed?`/`ensure_runtime!`, **registry auth**
(`registry_auth`/`registry_insecure`/`registry_ca_certs` on `create`, for
private/authenticated registries), and the typed error hierarchy.

Create options now cover `image`, `cpus`, `memory`, `oci_upper_size`, `env`,
`workdir`, `shell`, `user`, `hostname`, `labels`, `scripts`, `entrypoint`,
`ports`/`ports_udp`, `volumes`, `patches`, `network` (policy presets
`public_only`/`none`/`allow_all`/`non_local`, or a custom `NetworkPolicy`/Hash),
`log_level`, `quiet_logs`, `security`, `max_duration`, `idle_timeout`, `rlimits`,
`pull_policy`, `registry_auth`/`registry_insecure`/`registry_ca_certs`,
`secrets`, `from_snapshot`, `detached`, and `replace`/`replace_with_timeout`.
`exec`/`shell` add per-call `rlimits`.

## Verification

The binding is verified at four levels:

1. **Unit** (several hundred examples) — the Ruby layer's option normalization
   and value objects, with the native layer stubbed.
2. **Real-microVM integration** (`spec/integration`, opt-in via
   `MICROSANDBOX_INTEGRATION=1`) — boots actual sandboxes and round-trips
   `exec`/`shell`/`fs`/`metrics`/`logs`/streaming/snapshots. Run locally on
   macOS Apple Silicon and wired into CI on a KVM runner.
3. **Cross-SDK behavioral parity** — an identical-operations harness run through
   this gem and through the **official Go SDK** against the same embedded runtime
   produces byte-identical observable results (exec exit/stdout/success, env
   propagation, non-zero-exit handling, fs round-trip + size, metrics). Both wrap
   the same core crate, so this confirms the binding shapes data identically to
   the official SDKs.
4. **Packaged-gem install** — `gem install microsandbox-rb-<v>.gem` compiles the
   shipped Rust source via `extconf.rb` and the installed gem boots a real
   microVM, confirming the gem manifest and source-install path are complete.

**Roadmap:** the v1 roadmap (custom per-rule network policies, file patches,
interactive `attach`/`attach_shell`, SSH, and the raw agent client) is
implemented, and so is the bulk of the v0.5.8 configuration surface that a
later parity pass added: streaming image-pull progress, host-side `VolumeFs`,
streaming guest fs (`read_stream`/`write_stream`), the full secrets surface,
network configuration (DNS, TLS-interception tuning, IPv4/IPv6 pools,
`max_connections`, `trust_host_cas`), `init`/`ephemeral`/disk-image `fstype`
create options, full mount options (tmpfs/disk + stat-virtualization/
host-permissions), and snapshot inspection (`open`/`list_dir`/`reindex`).

A few **secondary** upstream knobs remain unexposed (a genuine binding gap, not
upstream-gated — they exist at the pinned `v0.6.1` runtime): per-published-port host
**bind address** (ports always bind loopback), network **interface overrides**,
and inline **named-volume create-mode** (pre-create with `Volume.create`, then
mount with `{ named: }`). These slot in module-by-module exactly as the existing
bindings do. Beyond those, surfacing genuinely newer core features is gated on
advancing the pinned core-crate tag.
