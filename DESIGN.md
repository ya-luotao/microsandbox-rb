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

## Core-crate dependency (self-contained)

`ext/microsandbox/Cargo.toml` depends on the core crate via a **pinned git tag**
(`microsandbox` / `microsandbox-network` at `v0.5.7`), so the gem builds anywhere
— CI, `rake-compiler-dock` release containers, and end-user source installs —
without an adjacent checkout. For fast local development against a sibling
microsandbox checkout, copy `.cargo/config.toml.example` to `.cargo/config.toml`
(gitignored); its `paths` override builds against the local crates instead of
git. The override must never be committed — it would break container builds.

## Packaging & releases

* **Source gem**: compiles the extension via `extconf.rb` (rb-sys
  `create_rust_makefile`); requires a Rust toolchain (MSRV below).
* **Precompiled platform gems**: built in CI on a `vX.Y.Z` tag
  (`.github/workflows/release.yml`) with `oxidize-rb/cross-gem-action`
  (`rake-compiler-dock`) per `Gem::Platform`, shipping multi-ABI
  `lib/microsandbox/<ruby_abi>/` native artifacts — the same model Node uses with
  per-platform packages. End users then install with no Rust toolchain. Published
  to RubyGems via Trusted Publishing (OIDC). See [Releasing](README.md#releasing).
  Whether the heavy core cross-builds for `arm64-darwin` under osxcross is
  confirmed on first run; if not, that platform moves to a native macOS runner.

## Build requirements

* Ruby >= 3.1, RubyGems >= 3.3.11
* Rust (stable) >= 1.91 — the core crate is edition 2024 and pulls `smoltcp`
  which sets MSRV 1.91. `rust-toolchain.toml` pins `stable`.
* Linux with KVM, or macOS on Apple Silicon (same as the other SDKs).

## Implemented surface (v1) vs roadmap

**v1 (this release):** sandbox lifecycle (`create`/`start`/`get`/`list`/`remove`/
`stop`/`kill`, block form), `exec`/`shell` with collected `ExecOutput`, the full
guest filesystem API (`fs.read`/`write`/`list`/`mkdir`/`remove`/`stat`/…),
`metrics`, `logs`, `version`/`install`/`installed?`, and the typed error
hierarchy.

**Roadmap:** streaming exec/logs/metrics (`exec_stream`, `log_stream`,
`metrics_stream`), named volumes, image management, snapshots, SSH, the raw
agent client, and fine-grained networking/secrets/patches options. The native
layer is structured so these slot in module-by-module, exactly as in the Python
binding.
