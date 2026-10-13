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
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};

use magnus::{function, prelude::*, Error, RModule, Ruby};
use microsandbox::{Backend, MicrosandboxError, Operation};

use crate::error;
use crate::runtime::{block_on, current_pid};

/// Resolve the ambient default backend, requiring it to be local.
///
/// Returns the `Arc<dyn Backend>` so the caller can keep it alive while
/// borrowing `&LocalBackend` from it (`as_local()` borrows the `Arc`). Pure
/// Rust — safe to call inside `block_on` (no Ruby C API), and it returns a raw
/// `MicrosandboxError` so the Ruby-exception mapping happens *after* `block_on`
/// re-acquires the GVL. It does not run [`ensure_this_process_backend`] (that
/// needs the GVL): the `block_on` it executes under already did. Cloud backends yield `Unsupported` for the given
/// operation (v0.6.8 `Operation`-keyed shape), mirroring pyo3's `resolve_local`.
pub fn local_backend(op: Operation) -> Result<Arc<dyn Backend>, MicrosandboxError> {
    let backend = microsandbox::default_backend();
    if backend.as_local().is_some() {
        Ok(backend)
    } else {
        Err(MicrosandboxError::local_only(op))
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
    operation: Operation,
    op: impl AsyncFnOnce(&microsandbox::LocalBackend) -> Result<T, MicrosandboxError>,
) -> Result<T, Error> {
    block_on(async move {
        let backend = local_backend(operation)?;
        let local = backend
            .as_local()
            .expect("local_backend() guarantees a local backend");
        op(local).await
    })?
    .map_err(error::to_ruby)
}

/// Build an `Arc<dyn Backend>` from the SDK facade. Ported from pyo3
/// `build_backend` (`sdk/python/src/lib.rs`) / node `build_backend`. Synchronous
/// (no network I/O): cloud construction only builds the HTTP client. Pure Rust
/// — it is also called with one of the mutexes below held, where calling into
/// Ruby (to build an exception) is not allowed; callers map the error
/// afterwards.
fn build_backend(
    kind: &str,
    url: Option<String>,
    api_key: Option<String>,
    profile: Option<String>,
) -> Result<Arc<dyn Backend>, MicrosandboxError> {
    match kind.trim().to_ascii_lowercase().as_str() {
        "local" => Ok(Arc::new(microsandbox::LocalBackend::lazy())),
        "cloud" => {
            let cloud = match profile {
                Some(profile) => microsandbox::CloudBackend::from_profile(&profile),
                None => match (url, api_key) {
                    (Some(url), Some(api_key)) => microsandbox::CloudBackend::new(url, api_key),
                    _ => {
                        return Err(MicrosandboxError::InvalidConfig(
                            "cloud backend requires url + api_key or profile".into(),
                        ))
                    }
                },
            }?;
            Ok(Arc::new(cloud))
        }
        other => Err(MicrosandboxError::InvalidConfig(format!(
            "backend kind must be 'local' or 'cloud', got {other:?}"
        ))),
    }
}

//--------------------------------------------------------------------------------------------------
// Fork safety: the backend generation
//--------------------------------------------------------------------------------------------------
//
// `fork(2)` copies only the calling thread. A child of a process that used the
// SDK inherits the core's process-wide default backend — a `LocalBackend`
// whose SQLite connections are each served by a worker thread that does not
// exist in the child, or a `CloudBackend` whose pooled connections belong to
// the parent's dead tokio runtime. Using it hangs (Linux: the pool's 30 s
// acquire timeout) or kills the process (macOS: waking the missing worker
// thread traps in libdispatch), and so does DROPPING it, because the
// destructor wakes the same threads.
//
// So the child never touches what it inherited: the first native call after a
// fork builds a fresh backend the same way the inherited one was chosen and
// swaps it in, and every inherited `Arc` is `mem::forget`-ed — leaked once per
// fork generation — instead of dropped.
//
// Locking. The three mutexes below are only ever taken on a Ruby thread that
// holds the GVL, and nothing that runs while one is held calls into Ruby or
// releases the GVL (which is why the code under them is pure Rust and Ruby
// exceptions are built after they are released). Ruby-level `fork` needs the
// GVL too, so no fork can happen while one of them is held: a child never
// inherits them locked.

/// How the current default backend was chosen, so a forked child can choose
/// it again. Deliberately not `Debug`: `Explicit` carries the cloud API key
/// (which the backend `Arc` in this process holds anyway — recording it here
/// adds no new exposure, as long as it is never printed).
#[derive(Clone)]
enum Selection {
    /// The core's own resolution ladder (`MSB_BACKEND`, `MSB_PROFILE`, the
    /// config file, else local): what `default_backend()` does on first use.
    Ladder,
    /// A `set_default_backend` / `with_backend` selection.
    Explicit {
        kind: String,
        url: Option<String>,
        api_key: Option<String>,
        profile: Option<String>,
    },
}

impl Selection {
    /// A fresh backend for this selection, owned by the calling process.
    fn build(&self) -> Result<Arc<dyn Backend>, MicrosandboxError> {
        match self {
            Selection::Ladder => microsandbox::resolve_default_backend(),
            Selection::Explicit {
                kind,
                url,
                api_key,
                profile,
            } => build_backend(kind, url.clone(), api_key.clone(), profile.clone()),
        }
    }
}

static SELECTION: Mutex<Selection> = Mutex::new(Selection::Ladder);

/// The pid of the process whose default backend the core currently holds.
/// 0 = no native operation has touched the backend in this process lineage.
static BACKEND_PID: AtomicU32 = AtomicU32::new(0);

static REBUILD_LOCK: Mutex<()> = Mutex::new(());

/// Lock one of this module's mutexes. A poisoned one is recovered: the data
/// behind them stays consistent across a panic (plain assignments), and
/// refusing to go on would only turn one failure into a permanent one.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Make sure the core's default backend belongs to THIS process, rebuilding it
/// after a fork. Every Ruby-facing entry that can reach the default backend
/// runs this first: [`crate::runtime::block_on`] for the async operations, and
/// each synchronous entry that reads the backend itself. (The two that are
/// about to replace the default anyway — `set_default_backend` and
/// `push_default_backend` — adopt with their own selection instead.)
///
/// Runs only with the GVL held — never inside a future (see the locking note
/// above).
pub fn ensure_this_process_backend() -> Result<(), Error> {
    // The Ruby exception is built here, after the locks are released.
    adopt_backend(current_pid(), None)
        .map(|_| ())
        .map_err(error::to_ruby)
}

/// Take the backend state over for process `cur` if it still belongs to a
/// parent process: install a backend built in this process and leak every
/// inherited one.
///
/// What gets installed is `replacement` when the caller is itself selecting a
/// backend, and otherwise a rebuild of the inherited selection. The difference
/// matters when the inherited selection no longer resolves in the child (say
/// the ladder now reads `MSB_BACKEND=cloud` without credentials): the rebuild
/// fails, and keeps failing on every call, but an explicit selection must
/// still get the child out of that state — so it never depends on the
/// inherited one.
///
/// Returns `Some(inherited selection)` when `replacement` was installed here
/// (the caller has nothing left to install), `None` when the caller proceeds
/// as in any process that already owns its backend. On an error nothing has
/// changed, `BACKEND_PID` included, so the next call tries again.
fn adopt_backend(
    cur: u32,
    replacement: Option<&Selection>,
) -> Result<Option<Selection>, MicrosandboxError> {
    if BACKEND_PID.load(Ordering::Acquire) == cur {
        return Ok(None);
    }
    let _rebuild = lock(&REBUILD_LOCK);
    let seen = BACKEND_PID.load(Ordering::Acquire);
    if seen == cur {
        return Ok(None);
    }
    if seen == 0 {
        // Nothing was inherited; the core resolves its default lazily, in this
        // process, on first use.
        BACKEND_PID.store(cur, Ordering::Release);
        return Ok(None);
    }

    // A process that used the backend forked us. Build ours first, so that a
    // failure leaves everything as it was.
    let fresh = match replacement {
        Some(selection) => selection.build()?,
        None => lock(&SELECTION).build()?,
    };
    // The inherited default must never be dropped (see above).
    std::mem::forget(microsandbox::swap_default_backend(fresh));
    // Neither may the backends that open `with_backend` scopes saved for their
    // restore. The entries themselves stay — pid and selection — so a scope
    // the parent opened can still be closed here (see `pop_default_backend`).
    for scope in lock(backend_scopes()).values_mut() {
        std::mem::forget(scope.previous.take());
    }
    let inherited =
        replacement.map(|selection| std::mem::replace(&mut *lock(&SELECTION), selection.clone()));
    BACKEND_PID.store(cur, Ordering::Release);
    Ok(inherited)
}

/// Install a process-wide default backend. Synchronous (an `RwLock` write) — no
/// `block_on`. Mirrors Python `set_default_backend` / Node `setDefaultBackend`.
fn set_default_backend(
    kind: String,
    url: Option<String>,
    api_key: Option<String>,
    profile: Option<String>,
) -> Result<(), Error> {
    let selection = Selection::Explicit {
        kind,
        url,
        api_key,
        profile,
    };
    // A forked child that starts by selecting a backend: the inherited default
    // is forgotten and this selection installed in its place, without ever
    // rebuilding the inherited one.
    if adopt_backend(current_pid(), Some(&selection))
        .map_err(error::to_ruby)?
        .is_some()
    {
        return Ok(());
    }
    microsandbox::set_default_backend(selection.build().map_err(error::to_ruby)?);
    *lock(&SELECTION) = selection;
    Ok(())
}

// Scoped-override registry. `with_backend` in Ruby is a swap-and-restore around
// a synchronous block, so it cannot use the core's async task-local
// `with_backend`. We mirror Node's process-wide push/pop token registry: push
// swaps the default and stores the previous backend under a fresh token; pop
// restores it. The Ruby wrapper drives this through an `ensure` block.
static NEXT_BACKEND_SCOPE: AtomicU32 = AtomicU32::new(1);
static BACKEND_SCOPES: OnceLock<Mutex<HashMap<u32, Scope>>> = OnceLock::new();

/// What an open `with_backend` scope restores when it closes.
struct Scope {
    /// The process that opened the scope.
    pid: u32,
    /// The backend that was the default before the push, kept to be put back
    /// by a pop in the same process. `None` when there is no such backend of
    /// this process's own: a forked child took it out to leak it, or the push
    /// was the child's first use of the backend and replaced an inherited
    /// default ([`adopt_backend`]). The pop then rebuilds from `selection`.
    previous: Option<Arc<dyn Backend>>,
    /// How that previous backend had been chosen: what a rebuild starts from,
    /// and what `SELECTION` goes back to when the scope closes.
    selection: Selection,
}

fn backend_scopes() -> &'static Mutex<HashMap<u32, Scope>> {
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
    let cur = current_pid();
    let selection = Selection::Explicit {
        kind,
        url,
        api_key,
        profile,
    };
    let (previous, before) = match adopt_backend(cur, Some(&selection)).map_err(error::to_ruby)? {
        // A forked child's first use of the backend: the scoped backend
        // replaced the inherited default (now forgotten), so there is nothing
        // of this process to put back. The pop rebuilds from how the inherited
        // default had been chosen.
        Some(inherited) => (None, inherited),
        None => {
            let previous =
                microsandbox::swap_default_backend(selection.build().map_err(error::to_ruby)?);
            let before = std::mem::replace(&mut *lock(&SELECTION), selection);
            (Some(previous), before)
        }
    };
    let token = NEXT_BACKEND_SCOPE.fetch_add(1, Ordering::Relaxed);
    lock(backend_scopes()).insert(
        token,
        Scope {
            pid: cur,
            previous,
            selection: before,
        },
    );
    Ok(token)
}

/// Close the scope opened by [`push_default_backend`]: restore the backend it
/// saved.
///
/// A pop consumes its token whether or not it succeeds. It can fail only in a
/// forked child, where the saved backend is the parent's and has to be rebuilt
/// from how it had been chosen: if that selection no longer resolves there,
/// the scope is closed anyway and the temporary backend stays selected — a
/// state the caller can describe and leave with `set_default_backend`, where a
/// token nobody can retry (`with_backend` never hands it out) would not be.
fn pop_default_backend(token: u32) -> Result<(), Error> {
    // In a forked child whose first native call is this pop (the parent forked
    // inside a `with_backend` block and the child now leaves it), this swaps
    // the inherited default for a fresh build of the scoped backend and
    // forgets the inherited `Arc`s, the one this scope saved included. The
    // rebuild below then swaps again, to what the scope restores.
    let adopted = ensure_this_process_backend();
    let cur = current_pid();

    // (The registry lock is not held while an exception is built.)
    let Some(scope) = lock(backend_scopes()).remove(&token) else {
        adopted?;
        return Err(error::base_error("unknown backend scope token"));
    };
    if let Err(e) = adopted {
        // Not even the scoped backend could be rebuilt in this process, so
        // everything in sight is still the parent's: leak what the scope
        // saved, and report. The scoped selection stays the recorded one.
        std::mem::forget(scope.previous);
        return Err(e);
    }

    match scope.previous {
        // Opened and closed in the same process: put the saved backend back.
        Some(previous) if scope.pid == cur => microsandbox::set_default_backend(previous),
        // No backend of this process's own was saved (see `Scope::previous`):
        // restore one built here from how the saved one had been chosen. On
        // failure the temporary backend stays selected (see above). The
        // default being replaced was built in this process and could be
        // dropped safely; it is forgotten all the same, so that no path of a
        // forked child ever drops a backend it might have inherited. That
        // leaks at most one backend per scope closed this way.
        previous => {
            // `None` unless the pid of the process that opened the scope was
            // reused; an inherited `Arc` is leaked either way.
            std::mem::forget(previous);
            let fresh = scope.selection.build().map_err(error::to_ruby)?;
            std::mem::forget(microsandbox::swap_default_backend(fresh));
        }
    }
    *lock(&SELECTION) = scope.selection;
    Ok(())
}

/// The active default backend kind: `"local"` or `"cloud"`. First call lazily
/// resolves the env/profile/config ladder. Synchronous (an `RwLock` read).
fn default_backend_kind() -> Result<String, Error> {
    ensure_this_process_backend()?;
    Ok(match microsandbox::default_backend().kind() {
        microsandbox::BackendKind::Local => "local",
        microsandbox::BackendKind::Cloud => "cloud",
    }
    .to_string())
}

/// Secret-safe description of the active default backend (v0.6.9):
/// {kind, api_url, source, profile}. `source` names what selected the backend
/// (e.g. "MSB_BACKEND", "programmatic", "default"); the API key is never
/// included. Like `default_backend_kind`, the first call freezes ambient
/// env/profile resolution for the process.
fn default_backend_info() -> Result<magnus::RHash, Error> {
    ensure_this_process_backend()?;
    let info = microsandbox::default_backend_info();
    let hash = crate::runtime::ruby().hash_new();
    let _ = hash.aset(
        "kind",
        match info.kind {
            microsandbox::BackendKind::Local => "local",
            microsandbox::BackendKind::Cloud => "cloud",
        },
    );
    let _ = hash.aset("api_url", info.api_url);
    let _ = hash.aset("source", info.source.as_str());
    let _ = hash.aset("profile", info.profile);
    Ok(hash)
}

pub fn define(_ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    native.define_singleton_method("set_default_backend", function!(set_default_backend, 4))?;
    native.define_singleton_method("push_default_backend", function!(push_default_backend, 4))?;
    native.define_singleton_method("pop_default_backend", function!(pop_default_backend, 1))?;
    native.define_singleton_method("default_backend_kind", function!(default_backend_kind, 0))?;
    native.define_singleton_method("default_backend_info", function!(default_backend_info, 0))?;
    Ok(())
}
