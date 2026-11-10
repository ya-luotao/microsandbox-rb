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
mod storage;
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

/// The effective local runtime configuration: the persisted config file, then
/// `MSB_HOME`/`MSB_PATH`/`MSB_LIBKRUNFW_PATH`, the SDK path slots and managed
/// policy, layered exactly as the local backend layers them (`overrides_json`
/// adds `home`/`msb_path`/`libkrunfw_path` on top). Reads files and the
/// environment only — no backend is built.
fn effective_runtime_config(
    overrides_json: &str,
) -> microsandbox::MicrosandboxResult<microsandbox::config::GlobalConfig> {
    microsandbox::setup::binding_runtime_config(overrides_json)
}

/// Whether the runtime HOME of `config` already holds a complete `msb` +
/// `libkrunfw` pair — exactly the pair an install would write. Explicit paths
/// (`MSB_PATH`, the SDK slots, `config.paths`) are cleared first so they can
/// neither satisfy nor mask the check: `setup` targets the home. Presence
/// only, like upstream's `is_runtime_installed` (the version-aware decision is
/// `Microsandbox.install`'s, in Ruby).
fn home_runtime_complete(config: &microsandbox::config::GlobalConfig) -> bool {
    let mut home_only = config.clone();
    home_only.paths.msb = None;
    home_only.paths.libkrunfw = None;
    matches!(
        microsandbox::setup::resolve_runtime(&home_only),
        Ok(runtime) if runtime.origin == microsandbox::setup::RuntimeOrigin::Home
    )
}

/// A resolved runtime pair as the Ruby Hash `runtime_info` returns:
/// `{"msb_path", "libkrunfw_path", "origin"}`, origin in upstream's snake_case
/// `RuntimeOrigin` spelling (`environment`, `sdk_package`, `configuration`,
/// `home`, `installed`).
fn resolved_runtime_to_hash(
    runtime: &microsandbox::setup::ResolvedRuntime,
) -> Result<RHash, Error> {
    let origin = serde_json::to_value(runtime.origin)
        .ok()
        .and_then(|value| value.as_str().map(str::to_string))
        .unwrap_or_else(|| format!("{:?}", runtime.origin).to_lowercase());
    let hash = runtime::ruby().hash_new();
    hash.aset("msb_path", runtime.msb_path.to_string_lossy().into_owned())?;
    hash.aset(
        "libkrunfw_path",
        runtime.libkrunfw_path.to_string_lossy().into_owned(),
    )?;
    hash.aset("origin", origin)?;
    Ok(hash)
}

/// The `msb` + `libkrunfw` pair the local backend would launch, resolved from
/// the effective runtime configuration (environment, SDK slots, config file,
/// home, packaged slot — `effective_runtime_config`) without touching the
/// network or the filesystem. Raises `RuntimeNotInstalledError` when nothing
/// resolves and `RuntimeIncompleteError` for a partial or unpaired source.
/// Independent of the selected backend (cloud included): it describes the host.
fn runtime_info() -> Result<RHash, Error> {
    let config = effective_runtime_config("{}").map_err(error::to_ruby)?;
    let runtime = microsandbox::setup::resolve_runtime(&config).map_err(error::to_ruby)?;
    resolved_runtime_to_hash(&runtime)
}

/// The runtime version embedded in the `msb` at `path` (its `.msbver`
/// section), or nil when it has none: a pre-0.7 `msb`, or a wrapper script
/// (`#!`), which the launch contract also treats as unversioned. Reads the
/// file only; never executes it.
fn msb_version(path: String) -> Result<Option<String>, Error> {
    use std::io::Read as _;
    let mut head = [0u8; 2];
    let is_script = std::fs::File::open(&path)
        .and_then(|mut file| file.read_exact(&mut head))
        .map(|()| &head == b"#!")
        .unwrap_or(false);
    if is_script {
        return Ok(None);
    }
    microsandbox::setup::resolve_runtime_version(&path)
        .map(|version| version.map(|v| v.to_string()))
        .map_err(error::to_ruby)
}

/// The exact pair an install writes into the runtime home:
/// `[<home>/bin/<msb>, <home>/lib/<libkrunfw>]`, with the OS-specific file
/// names upstream's resolver expects (`runtime_in_home`). The home comes from
/// the effective configuration (`MSB_HOME`, the config file, default
/// `~/.microsandbox`).
fn runtime_home_pair() -> Result<(String, String), Error> {
    let config = effective_runtime_config("{}").map_err(error::to_ruby)?;
    let home = config.home();
    let os = std::env::consts::OS;
    let msb = home
        .join(microsandbox_utils::BIN_SUBDIR)
        .join(microsandbox_utils::msb_binary_filename(os));
    let lib = home
        .join(microsandbox_utils::LIB_SUBDIR)
        .join(microsandbox_utils::libkrunfw_filename(os));
    Ok((
        msb.to_string_lossy().into_owned(),
        lib.to_string_lossy().into_owned(),
    ))
}

/// Install the runtime pair into the runtime home through upstream's
/// installer. `opts` (all optional): source (`release_download` (default),
/// `archive`, `directory`, `embedded_archive`), source_path, version, force,
/// verify, expected_archive_sha256 — upstream's binding wire
/// (`binding_install_options`). Returns the installed pair in `runtime_info`'s
/// shape. Unconditional: the "is there anything to do" decision is
/// `Microsandbox.install`'s. Never touches the backend, so a forked child does
/// not take the inherited one over here (see `runtime::block_on_runtime_install`).
fn install_runtime(opts: RHash) -> Result<RHash, Error> {
    let mut install_opts = serde_json::Map::new();
    for key in [
        "source",
        "source_path",
        "version",
        "expected_archive_sha256",
    ] {
        if let Some(value) = conv::opt_string(opts, key)? {
            install_opts.insert(key.into(), value.into());
        }
    }
    if conv::opt_bool(opts, "force")? {
        install_opts.insert("force".into(), true.into());
    }
    if let Some(verify) = conv::opt::<bool>(opts, "verify")? {
        install_opts.insert("verify".into(), verify.into());
    }
    let options = microsandbox::setup::binding_install_options(
        &serde_json::Value::Object(install_opts).to_string(),
    )
    .map_err(error::to_ruby)?;
    let config = effective_runtime_config("{}").map_err(error::to_ruby)?;
    let runtime = runtime::block_on_runtime_install(async move {
        microsandbox::setup::install_runtime(&config, options).await
    })?
    .map_err(error::to_ruby)?;
    resolved_runtime_to_hash(&runtime)
}

/// Customizable install. `opts`: base_dir (the runtime home to install into),
/// version (the release to download), force (replace a complete installation —
/// repairs a corrupt one; without it a complete pair in the home is kept, as
/// with `install`), skip_verify. Built on upstream's language-SDK
/// bindings (`binding_runtime_config` / `binding_install_options`), the same
/// wire the official SDKs use.
fn setup(opts: RHash) -> Result<(), Error> {
    let mut runtime_cfg = serde_json::Map::new();
    if let Some(dir) = conv::opt_string(opts, "base_dir")? {
        runtime_cfg.insert("home".into(), dir.into());
    }
    let mut install_opts = serde_json::Map::new();
    if let Some(version) = conv::opt_string(opts, "version")? {
        install_opts.insert("version".into(), version.into());
    }
    if conv::opt_bool(opts, "force")? {
        install_opts.insert("force".into(), true.into());
    }
    if conv::opt_bool(opts, "skip_verify")? {
        install_opts.insert("verify".into(), false.into());
    }
    let force = install_opts.contains_key("force");
    let config = effective_runtime_config(&serde_json::Value::Object(runtime_cfg).to_string())
        .map_err(error::to_ruby)?;
    // As `install`: a complete pair in the target home is kept unless forced.
    if !force && home_runtime_complete(&config) {
        return Ok(());
    }
    let options = microsandbox::setup::binding_install_options(
        &serde_json::Value::Object(install_opts).to_string(),
    )
    .map_err(error::to_ruby)?;
    // Backend-free, like `install`.
    runtime::block_on_runtime_install(async move {
        microsandbox::setup::install_runtime(&config, options)
            .await
            .map(|_| ())
    })?
    .map_err(error::to_ruby)
}

/// Whether a complete `msb` + `libkrunfw` pair resolves from any source the
/// local backend would use (environment, SDK slots, config, home, packaged).
/// Presence only: it says nothing about the version (see `Microsandbox.ensure_runtime!`).
/// A configuration that cannot be loaded counts as "not installed".
fn is_installed() -> bool {
    effective_runtime_config("{}")
        .map(|config| microsandbox::setup::is_runtime_installed(&config))
        .unwrap_or(false)
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
    native.define_singleton_method("runtime_info", function!(runtime_info, 0))?;
    native.define_singleton_method("msb_version", function!(msb_version, 1))?;
    native.define_singleton_method("runtime_home_pair", function!(runtime_home_pair, 0))?;
    native.define_singleton_method("install_runtime", function!(install_runtime, 1))?;
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
    storage::define(ruby, &native)?;

    Ok(())
}
