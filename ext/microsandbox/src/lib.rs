//! Ruby SDK native extension for microsandbox.
//!
//! The Ruby analogue of the official Python (pyo3) and Node (napi) bindings: it
//! exposes the embedded `microsandbox` runtime to Ruby via magnus. The core is
//! async (tokio); the Ruby API is synchronous, so every binding blocks on a
//! shared multi-threaded tokio runtime with the GVL released (see `runtime`).
//!
//! Everything here lives under `Microsandbox::Native`; the ergonomic, idiomatic
//! surface is the pure-Ruby layer in `lib/microsandbox/`.

mod agent;
mod backend;
mod conv;
mod error;
mod exec;
mod fs_stream;
mod host_path;
mod image;
mod runtime;
mod sandbox;
mod snapshot;
mod ssh;
mod stream;
mod volume;

use magnus::{function, prelude::*, Error, RHash, Ruby};

/// Gem/runtime version string.
fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Latest metrics for every running sandbox, as a `{ name => metrics_hash }`
/// Ruby Hash. Mirrors the official `all_sandbox_metrics` / `allSandboxMetrics`
/// helpers (Python/Node/Go).
fn all_sandbox_metrics() -> Result<RHash, Error> {
    let map =
        backend::with_local_backend(microsandbox::Operation::AllSandboxMetrics, async |local| {
            microsandbox::sandbox::all_sandbox_metrics_local(local).await
        })?;
    let hash = runtime::ruby().hash_new();
    for (name, metrics) in &map {
        hash.aset(name.as_str(), sandbox::metrics_to_hash(metrics))?;
    }
    Ok(hash)
}

/// Download and install the `msb` runtime + `libkrunfw` into `~/.microsandbox`.
/// Never touches the backend, so a forked child does not take the inherited
/// one over here (see `runtime::block_on_runtime_install`).
fn install() -> Result<(), Error> {
    runtime::block_on_runtime_install(microsandbox::setup::install())?.map_err(error::to_ruby)
}

/// Customizable install via the core `Setup` builder. `opts`: base_dir (install
/// root), version (pin the runtime version), force (re-download even if present
/// — repairs a corrupt install), skip_verify. Mirrors the Node `Setup` builder.
fn setup(opts: RHash) -> Result<(), Error> {
    use microsandbox::setup::Setup;
    let base_dir = conv::opt_string(opts, "base_dir")?;
    let version = conv::opt_string(opts, "version")?;
    let skip_verify = conv::opt_bool(opts, "skip_verify")?;
    let force = conv::opt_bool(opts, "force")?;
    // `Setup` uses a typed-builder whose `strip_option` setters change the type
    // on each call, so optional fields can't be set conditionally on one binding
    // — branch on presence instead (matching the Node binding).
    let setup = match (base_dir, version) {
        (Some(d), Some(v)) => Setup::builder()
            .base_dir(d)
            .version(v)
            .skip_verify(skip_verify)
            .force(force)
            .build(),
        (Some(d), None) => Setup::builder()
            .base_dir(d)
            .skip_verify(skip_verify)
            .force(force)
            .build(),
        (None, Some(v)) => Setup::builder()
            .version(v)
            .skip_verify(skip_verify)
            .force(force)
            .build(),
        (None, None) => Setup::builder()
            .skip_verify(skip_verify)
            .force(force)
            .build(),
    };
    // Backend-free, like `install`.
    runtime::block_on_runtime_install(setup.install())?.map_err(error::to_ruby)
}

/// Whether the `msb` runtime + `libkrunfw` are installed and resolvable.
fn is_installed() -> bool {
    microsandbox::setup::is_installed()
}

/// Override the resolved `msb` runtime path (SDK tier of the resolver).
fn set_runtime_msb_path(path: String) {
    microsandbox::config::set_sdk_msb_path(path);
}

/// Override the resolved `libkrunfw` path (SDK tier of the resolver). Set-once
/// per process; the `MSB_LIBKRUNFW_PATH` env var still takes precedence. Mirrors
/// `set_runtime_msb_path` for the libkrunfw shared library.
fn set_runtime_libkrunfw_path(path: String) {
    microsandbox::config::set_sdk_libkrunfw_path(path);
}

/// The currently-resolved `msb` runtime path. Synchronous (filesystem probes,
/// no async) — runs on the Ruby thread; resolves the path from the local
/// backend's config.
fn resolved_msb_path() -> Result<String, Error> {
    backend::ensure_this_process_backend()?;
    let backend = microsandbox::default_backend();
    // Shim-only entry point with no SDK `Operation` — report the Ruby-facing
    // name (`Microsandbox.runtime_path`), like Python's name-based local_only.
    let local = backend
        .as_local()
        .ok_or_else(|| error::local_only("runtime_path"))?;
    let path = local.config().resolve_msb_path().map_err(error::to_ruby)?;
    Ok(path.to_string_lossy().into_owned())
}

/// This process's fork generation (see `runtime::ProcessIdentity`): how many
/// `fork`s led from the process that loaded the extension to this one. A
/// diagnostic for the fork specs, not part of the Ruby API (nothing in
/// `lib/` calls it, and `Native` is the extension's internal namespace).
fn fork_generation() -> u32 {
    runtime::ProcessIdentity::current().generation()
}

/// Whether two given identities are the same process, by the two comparisons
/// every ownership decision uses: `PartialEq` (the runtime cell, handles,
/// `with_backend` scopes) and the packed word (the backend record). Returns
/// `[equal, same_bits]`. A spec-only diagnostic, like `fork_generation`:
/// pid reuse cannot be staged on demand, so this is where the specs pin that
/// both the pid and the generation take part. Pure: no state is read or
/// changed.
fn fork_identity_equal(pid_a: u32, gen_a: u32, pid_b: u32, gen_b: u32) -> (bool, bool) {
    let a = runtime::ProcessIdentity::from_parts(pid_a, gen_a);
    let b = runtime::ProcessIdentity::from_parts(pid_b, gen_b);
    (a == b, a.to_bits() == b.to_bits())
}

/// Run a handle's real ownership check (`ForkGuarded::get_in`) for a handle
/// created by the process (`born_pid`, `born_gen`) and used in (`cur_pid`,
/// `cur_gen`): `nil` when it is allowed, the `ForkedHandleError` that `get`
/// would raise otherwise — including the equal-pid wording. Spec-only and
/// pure, like `fork_identity_equal`; the guard holds no payload.
fn fork_identity_guard(
    born_pid: u32,
    born_gen: u32,
    cur_pid: u32,
    cur_gen: u32,
) -> Result<(), Error> {
    let born = runtime::ProcessIdentity::from_parts(born_pid, born_gen);
    let cur = runtime::ProcessIdentity::from_parts(cur_pid, cur_gen);
    let guard = runtime::ForkGuarded::owned_by(born, "Microsandbox::VolumeFs", ());
    guard.get_in(cur).map(|_| ())
}

/// magnus entry point. RubyGems loads this via `require "microsandbox/microsandbox_rb"`,
/// which calls `Init_microsandbox_rb` (matching the cdylib `[lib] name`).
#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    // Before anything can fork: from here on every fork's child gets a fork
    // generation one higher than its parent's (see `runtime::ProcessIdentity`).
    runtime::register_fork_handler();

    let module = ruby.define_module("Microsandbox")?;
    let native = module.define_module("Native")?;

    native.define_singleton_method("version", function!(version, 0))?;
    native.define_singleton_method("install", function!(install, 0))?;
    native.define_singleton_method("setup", function!(setup, 1))?;
    native.define_singleton_method("installed?", function!(is_installed, 0))?;
    native.define_singleton_method("set_runtime_msb_path", function!(set_runtime_msb_path, 1))?;
    native.define_singleton_method(
        "set_runtime_libkrunfw_path",
        function!(set_runtime_libkrunfw_path, 1),
    )?;
    native.define_singleton_method("resolved_msb_path", function!(resolved_msb_path, 0))?;
    native.define_singleton_method("all_sandbox_metrics", function!(all_sandbox_metrics, 0))?;
    native.define_singleton_method("fork_generation", function!(fork_generation, 0))?;
    native.define_singleton_method("fork_identity_equal", function!(fork_identity_equal, 4))?;
    native.define_singleton_method("fork_identity_guard", function!(fork_identity_guard, 4))?;

    backend::define(ruby, &native)?;
    sandbox::define(ruby, &native)?;
    exec::define(ruby, &native)?;
    stream::define(ruby, &native)?;
    fs_stream::define(ruby, &native)?;
    snapshot::define(ruby, &native)?;
    image::define(ruby, &native)?;
    volume::define(ruby, &native)?;
    agent::define(ruby, &native)?;
    ssh::define(ruby, &native)?;

    Ok(())
}
