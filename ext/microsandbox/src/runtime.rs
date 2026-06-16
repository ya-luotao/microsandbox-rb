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
use std::sync::OnceLock;

use tokio::runtime::Runtime;

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// The process-wide multi-threaded tokio runtime, built on first use.
pub fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("microsandbox-rb")
            .build()
            .expect("microsandbox: failed to build tokio runtime")
    })
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
