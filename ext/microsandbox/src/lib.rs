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
    let map = backend::with_local_backend(async |local| {
        microsandbox::sandbox::all_sandbox_metrics(local).await
    })?;
    let hash = runtime::ruby().hash_new();
    for (name, metrics) in &map {
        hash.aset(name.as_str(), sandbox::metrics_to_hash(metrics))?;
    }
    Ok(hash)
}

/// Download and install the `msb` runtime + `libkrunfw` into `~/.microsandbox`.
fn install() -> Result<(), Error> {
    runtime::block_on(microsandbox::setup::install()).map_err(error::to_ruby)
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
    runtime::block_on(setup.install()).map_err(error::to_ruby)
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
    let backend = microsandbox::default_backend();
    let local = backend.as_local().ok_or_else(|| {
        error::to_ruby(microsandbox::MicrosandboxError::Unsupported {
            feature: "resolved_msb_path requires a local backend".into(),
            available_when: "with the local backend".into(),
        })
    })?;
    let path = microsandbox::config::resolve_msb_path(local.config()).map_err(error::to_ruby)?;
    Ok(path.to_string_lossy().into_owned())
}

/// magnus entry point. RubyGems loads this via `require "microsandbox/microsandbox_rb"`,
/// which calls `Init_microsandbox_rb` (matching the cdylib `[lib] name`).
#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
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
