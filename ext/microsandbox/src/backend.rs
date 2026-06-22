//! Backend routing: the ambient process-wide backend and its selection surface.
//!
//! Mirrors the official Python (`sdk/python/src/lib.rs`) and Node
//! (`sdk/node-ts/native/runtime_config.rs`) bindings. As of upstream v0.5.8
//! (PR #754) every operation routes through a [`microsandbox::Backend`]: the
//! ambient default is a lazily-initialised [`microsandbox::LocalBackend`], and
//! callers may install a different default process-wide or for a scoped block.
//!
//! Local-only operations (image cache, aggregate metrics, `msb` path) need a
//! concrete `&LocalBackend`; [`local_backend`] resolves the ambient default and
//! downcasts it, surfacing a clean [`MicrosandboxError::Unsupported`] under a
//! cloud backend (exactly as the pyo3 `resolve_local` helper does). The backend
//! selection setters (`set_default_backend` / `with_backend` push-pop /
//! `default_backend_kind`) deliberately expose only a `kind`/`url`/`api_key`/
//! `profile` facade — the raw `LocalBackend`/`CloudBackend` builders stay hidden,
//! matching Python and Node.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use magnus::{function, prelude::*, Error, RModule, Ruby};
use microsandbox::{Backend, MicrosandboxError};

use crate::error;
use crate::runtime::block_on;

/// Resolve the ambient default backend, requiring it to be local.
///
/// Returns the `Arc<dyn Backend>` so the caller can keep it alive while
/// borrowing `&LocalBackend` from it (`as_local()` borrows the `Arc`). Pure
/// Rust — safe to call inside `block_on` (no Ruby C API), and it returns a raw
/// `MicrosandboxError` so the Ruby-exception mapping happens *after* `block_on`
/// re-acquires the GVL. Cloud backends yield `Unsupported`, mirroring pyo3's
/// `resolve_local`.
pub fn local_backend() -> Result<Arc<dyn Backend>, MicrosandboxError> {
    let backend = microsandbox::default_backend();
    if backend.as_local().is_some() {
        Ok(backend)
    } else {
        Err(MicrosandboxError::Unsupported {
            feature: "this operation requires a local backend".into(),
            available_when: "with the local backend (the default)".into(),
        })
    }
}

/// Resolve the ambient backend (requiring it to be local), then run `op` with a
/// borrowed `&LocalBackend` inside the blocking runtime, mapping any core error
/// to a Ruby exception. Local-only operations (image cache, aggregate metrics)
/// share this instead of repeating the resolve/downcast dance; the single
/// `as_local()` unwrap is provably infallible — [`local_backend`] just checked
/// it and returns the same `Arc` kept alive for the borrow — so it lives here
/// once rather than at every call site.
pub fn with_local_backend<T>(
    op: impl AsyncFnOnce(&microsandbox::LocalBackend) -> Result<T, MicrosandboxError>,
) -> Result<T, Error> {
    block_on(async move {
        let backend = local_backend()?;
        let local = backend
            .as_local()
            .expect("local_backend() guarantees a local backend");
        op(local).await
    })
    .map_err(error::to_ruby)
}

/// Build an `Arc<dyn Backend>` from the SDK facade. Ported from pyo3
/// `build_backend` (`sdk/python/src/lib.rs`) / node `build_backend`. Synchronous
/// (no network I/O): cloud construction only builds the HTTP client. Runs on the
/// Ruby thread with the GVL held, so it may map errors to Ruby directly.
fn build_backend(
    kind: String,
    url: Option<String>,
    api_key: Option<String>,
    profile: Option<String>,
) -> Result<Arc<dyn Backend>, Error> {
    match kind.trim().to_ascii_lowercase().as_str() {
        "local" => Ok(Arc::new(microsandbox::LocalBackend::lazy())),
        "cloud" => {
            let cloud = match profile {
                Some(profile) => microsandbox::CloudBackend::from_profile(&profile),
                None => match (url, api_key) {
                    (Some(url), Some(api_key)) => microsandbox::CloudBackend::new(url, api_key),
                    _ => {
                        return Err(error::to_ruby(MicrosandboxError::InvalidConfig(
                            "cloud backend requires url + api_key or profile".into(),
                        )))
                    }
                },
            }
            .map_err(error::to_ruby)?;
            Ok(Arc::new(cloud))
        }
        other => Err(error::to_ruby(MicrosandboxError::InvalidConfig(format!(
            "backend kind must be 'local' or 'cloud', got {other:?}"
        )))),
    }
}

/// Install a process-wide default backend. Synchronous (an `RwLock` write) — no
/// `block_on`. Mirrors Python `set_default_backend` / Node `setDefaultBackend`.
fn set_default_backend(
    kind: String,
    url: Option<String>,
    api_key: Option<String>,
    profile: Option<String>,
) -> Result<(), Error> {
    microsandbox::set_default_backend(build_backend(kind, url, api_key, profile)?);
    Ok(())
}

// Scoped-override registry. `with_backend` in Ruby is a swap-and-restore around
// a synchronous block, so it cannot use the core's async task-local
// `with_backend`. We mirror Node's process-wide push/pop token registry: push
// swaps the default and stores the previous backend under a fresh token; pop
// restores it. The Ruby wrapper drives this through an `ensure` block.
static NEXT_BACKEND_SCOPE: AtomicU32 = AtomicU32::new(1);
static BACKEND_SCOPES: OnceLock<Mutex<HashMap<u32, Arc<dyn Backend>>>> = OnceLock::new();

fn backend_scopes() -> &'static Mutex<HashMap<u32, Arc<dyn Backend>>> {
    BACKEND_SCOPES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Swap in a new default backend and return a token for restoring the previous
/// one via [`pop_default_backend`]. Process-wide while active (not task-local):
/// concurrent Ruby threads observe the swapped default.
fn push_default_backend(
    kind: String,
    url: Option<String>,
    api_key: Option<String>,
    profile: Option<String>,
) -> Result<u32, Error> {
    let previous = microsandbox::swap_default_backend(build_backend(kind, url, api_key, profile)?);
    let token = NEXT_BACKEND_SCOPE.fetch_add(1, Ordering::Relaxed);
    backend_scopes()
        .lock()
        .map_err(|_| error::base_error("backend scope registry poisoned"))?
        .insert(token, previous);
    Ok(token)
}

/// Restore the backend saved by [`push_default_backend`].
fn pop_default_backend(token: u32) -> Result<(), Error> {
    let previous = backend_scopes()
        .lock()
        .map_err(|_| error::base_error("backend scope registry poisoned"))?
        .remove(&token)
        .ok_or_else(|| error::base_error("unknown backend scope token"))?;
    microsandbox::set_default_backend(previous);
    Ok(())
}

/// The active default backend kind: `"local"` or `"cloud"`. First call lazily
/// resolves the env/profile/config ladder. Synchronous (an `RwLock` read).
fn default_backend_kind() -> String {
    match microsandbox::default_backend().kind() {
        microsandbox::BackendKind::Local => "local",
        microsandbox::BackendKind::Cloud => "cloud",
    }
    .to_string()
}

pub fn define(_ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    native.define_singleton_method("set_default_backend", function!(set_default_backend, 4))?;
    native.define_singleton_method("push_default_backend", function!(push_default_backend, 4))?;
    native.define_singleton_method("pop_default_backend", function!(pop_default_backend, 1))?;
    native.define_singleton_method("default_backend_kind", function!(default_backend_kind, 0))?;
    Ok(())
}
