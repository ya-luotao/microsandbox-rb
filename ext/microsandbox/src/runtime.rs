//! Shared tokio runtime and the GVL-release bridge.
//!
//! The microsandbox core is async; the Ruby API is synchronous. Every native
//! method runs its future to completion on a single, process-wide multi-threaded
//! tokio runtime. Crucially, the blocking call happens inside [`nogvl`], which
//! releases Ruby's Global VM Lock for the duration so other Ruby threads keep
//! running while a (potentially long) sandbox operation is in flight.

use std::ffi::c_void;
use std::future::Future;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicPtr, AtomicU32, Ordering};
use std::sync::Mutex;

use magnus::Ruby;
use tokio::runtime::Runtime;

/// The current Ruby handle. Safe to call from any bound method or value
/// conversion: we always hold the GVL there (conversions run after `block_on`
/// returns and re-acquires it).
pub fn ruby() -> Ruby {
    Ruby::get().expect("microsandbox: not on a Ruby thread")
}

// The process-wide tokio runtime, guarded by the pid it was built under. A
// multi-threaded runtime owns worker + I/O-driver threads, and `fork(2)` copies
// ONLY the calling thread — so a child that inherits this runtime has a runtime
// whose threads are gone: `block_on` can still drive the current thread, but the
// background I/O that keeps e.g. the agent-relay connection alive never runs, so
// connections stall/drop mid-use. This is hit in practice by forking job servers
// (Solid Queue, Resque) and clustered web servers (Puma workers).
//
// Fix: store the runtime behind a leaked raw pointer tagged with the building
// pid. If `runtime()` is called in a process whose pid differs (we forked), build
// a FRESH runtime for this process and swap the pointer. The stale runtime is
// LEAKED, never dropped — dropping a tokio runtime whose worker threads vanished
// across fork can hang on the shutdown thread-join. One runtime is leaked per
// process that uses the SDK (bounded; equivalent to the old set-once behavior in
// the common no-fork case).
static RUNTIME_PTR: AtomicPtr<Runtime> = AtomicPtr::new(std::ptr::null_mut());
static RUNTIME_PID: AtomicU32 = AtomicU32::new(0);
static RUNTIME_LOCK: Mutex<()> = Mutex::new(());

fn build_runtime() -> Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("microsandbox-rb")
        .build()
        .expect("microsandbox: failed to build tokio runtime")
}

/// The multi-threaded tokio runtime for THIS process, built on first use and
/// rebuilt after a `fork(2)` (fork-safe — see the note above).
pub fn runtime() -> &'static Runtime {
    let cur = std::process::id();
    let ptr = RUNTIME_PTR.load(Ordering::Acquire);
    if !ptr.is_null() && RUNTIME_PID.load(Ordering::Acquire) == cur {
        // SAFETY: ptr was produced by Box::leak (valid for 'static) and matches
        // this process's pid, so its runtime threads are live in this process.
        return unsafe { &*ptr };
    }

    let _guard = RUNTIME_LOCK
        .lock()
        .expect("microsandbox: runtime lock poisoned");
    // Re-check under the lock (another thread may have just built it).
    let ptr = RUNTIME_PTR.load(Ordering::Acquire);
    if !ptr.is_null() && RUNTIME_PID.load(Ordering::Acquire) == cur {
        return unsafe { &*ptr };
    }

    // Build a fresh runtime for this process and publish it. The previous pointer
    // (if any) belonged to a parent process and is intentionally leaked, not
    // dropped (its threads are gone post-fork; Drop would block on join).
    let rt: &'static Runtime = Box::leak(Box::new(build_runtime()));
    RUNTIME_PTR.store(rt as *const Runtime as *mut Runtime, Ordering::Release);
    RUNTIME_PID.store(cur, Ordering::Release);
    rt
}

/// Run `f` with the Ruby GVL released.
///
/// `f` runs on the *same* OS thread (the C call blocks until it returns), so no
/// `Send`/`'static` bound is required. `f` MUST NOT touch the Ruby C API while
/// the GVL is released. Panics are caught and re-raised after the GVL is
/// re-acquired, because unwinding across the C frame would be undefined
/// behaviour.
pub fn nogvl<F, R>(f: F) -> R
where
    F: FnOnce() -> R,
{
    struct State<F, R> {
        f: Option<F>,
        out: Option<std::thread::Result<R>>,
    }

    unsafe extern "C" fn call<F, R>(arg: *mut c_void) -> *mut c_void
    where
        F: FnOnce() -> R,
    {
        // SAFETY: `arg` points to the `State` on the caller's stack, which
        // outlives this call (rb_thread_call_without_gvl blocks until return).
        let state = unsafe { &mut *(arg as *mut State<F, R>) };
        let f = state.f.take().expect("nogvl callback invoked twice");
        state.out = Some(catch_unwind(AssertUnwindSafe(f)));
        std::ptr::null_mut()
    }

    let mut state: State<F, R> = State {
        f: Some(f),
        out: None,
    };

    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(call::<F, R>),
            &mut state as *mut _ as *mut c_void,
            None,
            std::ptr::null_mut(),
        );
    }

    match state.out.take() {
        Some(Ok(value)) => value,
        Some(Err(panic)) => std::panic::resume_unwind(panic),
        None => unreachable!("nogvl callback did not run"),
    }
}

/// Drive a future to completion on the shared runtime with the GVL released.
pub fn block_on<F>(fut: F) -> F::Output
where
    F: Future,
{
    nogvl(|| runtime().block_on(fut))
}
