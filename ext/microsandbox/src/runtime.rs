//! Shared tokio runtime and the GVL-release bridge.
//!
//! The microsandbox core is async; the Ruby API is synchronous. Every native
//! method runs its future to completion on a single, process-wide multi-threaded
//! tokio runtime. Crucially, the blocking call happens inside [`nogvl`], which
//! releases Ruby's Global VM Lock for the duration so other Ruby threads keep
//! running while a (potentially long) sandbox operation is in flight.
//!
//! # Interrupts must not lose a result
//!
//! A native call cannot be interrupted while it runs (see `DESIGN.md`), so a
//! `Thread#raise` (what `Timeout.timeout` uses), a `Thread#kill` or the main
//! thread's SIGINT that arrives meanwhile is delivered *after* it. Ruby delivers
//! those by `longjmp`, which skips Rust frames without running destructors: if
//! that happened while the value the call just produced still lived only in a
//! Rust frame, the value — a booted sandbox, a guest exec session, megabytes of
//! output — would be neither returned to Ruby nor dropped. Two rules keep that
//! from happening; every bound method relies on both:
//!
//! 1. **[`nogvl`] never lets Ruby jump out of it.** It checks interrupts only
//!    *before* the work starts, under `rb_protect`, and reports one as an
//!    ordinary `Err` that unwinds the Rust frames normally. After the work it
//!    does not check at all (see the function for the CRuby details).
//! 2. **Between [`block_on`] returning and the bound method returning, the code
//!    must not run Ruby code or check interrupts**: no `funcall` (CRuby's
//!    `vm_call0_body` runs `RUBY_VM_CHECK_INTS` after *every* call it makes, C
//!    functions included), no `rb_thread_check_ints`, nothing that can enter a
//!    Ruby method body. Only C-level construction is allowed there — `rb_hash_*`,
//!    `rb_ary_*`, `rb_str_*`, number boxing, and `TypedData` wrapping. The one
//!    `funcall` magnus would otherwise make at that point — `#[magnus::wrap]`
//!    resolves its class with `const_get` the first time a value is wrapped — is
//!    moved to extension load by [`preload_class`]. Error construction
//!    (`error::to_ruby`) may call Ruby: on that path there is no value to lose.
//!
//! Together: after `block_on` returns `Ok`, the next interrupt checkpoint is
//! the Ruby VM's own, reached only once the bound method has handed its value
//! to Ruby (the first one is `vm_pop_frame` popping the native method's frame,
//! in `vm_call_cfunc_with_frame_`). From then on the value is an ordinary Ruby
//! object — returned to the caller, or garbage whose `free` drops the Rust
//! value. It is never abandoned.

use std::ffi::c_void;
use std::future::Future;
use std::mem::ManuallyDrop;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicPtr, AtomicU32, Ordering};

use magnus::{Error, Ruby, TypedData};
use tokio::runtime::Runtime;

use crate::error;

/// The current Ruby handle. Safe to call from any bound method or value
/// conversion: we always hold the GVL there (conversions run after `block_on`
/// returns and re-acquires it).
pub fn ruby() -> Ruby {
    Ruby::get().expect("microsandbox: not on a Ruby thread")
}

//--------------------------------------------------------------------------------------------------
// Process identity
//--------------------------------------------------------------------------------------------------

/// Which process this is, for fork safety: the pid plus a fork generation.
///
/// Everything fork-aware in the extension — the runtime cell below, the
/// backend record in `backend.rs`, [`ForkGuarded`] — tags what it builds with
/// the identity of the process that built it and compares that against
/// [`ProcessIdentity::current`] before use. Both halves are compared:
///
/// * The pid alone is not enough. A descendant can end up with the pid of an
///   ancestor whose state it inherited, if the pid counter wraps onto exactly
///   that value and no SDK call happened in between; it would then pass for
///   that ancestor.
/// * The generation alone is not enough either. It counts the `fork`s that
///   ran this library's atfork child handler, and a process can be created
///   without running it — `vfork`, a raw `clone` — in which case only the pid
///   tells the child apart.
///
/// Every `fork(2)` that runs atfork handlers (which `Kernel#fork` /
/// `Process.fork` always do: Ruby calls libc's `fork`) gives the child a
/// generation one higher than its parent's, so parent and child differ even
/// when their pids are equal.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct ProcessIdentity {
    pub pid: u32,
    generation: u32,
}

/// How many `fork`s, counted from the process that loaded the extension, led
/// to this process. Incremented only by [`on_fork_child`], in a child, and
/// inherited (as plain memory) by every child. 32 bits: it would take four
/// billion nested forks in one lineage to wrap, and a wrap matters only if
/// the pid matches as well.
static FORK_GENERATION: AtomicU32 = AtomicU32::new(0);

/// The `pthread_atfork` child handler. It runs in the new child before `fork`
/// returns there, while the child is single-threaded, and must be
/// async-signal-safe: one lock-free atomic add, nothing else (no allocation,
/// no lock, no Ruby). `Relaxed` is enough: the only thread that exists to read
/// the counter is this one, and threads started later see it through the
/// spawn's own synchronization. The parent never changes its counter.
extern "C" fn on_fork_child() {
    FORK_GENERATION.fetch_add(1, Ordering::Relaxed);
}

/// Register [`on_fork_child`]. Called once, from the extension's init.
///
/// Ruby never unloads (`dlclose`s) an extension, so the handler's code stays
/// mapped for the life of the process, as `pthread_atfork` requires — handlers
/// cannot be unregistered. If registration fails (`ENOMEM`), the generation
/// stays 0 and identity degrades to the pid alone, which is how the extension
/// behaved before the generation existed; that is not worth refusing to load
/// over. Platforms without `pthread_atfork` (the gem ships for macOS and
/// Linux only) get the same pid-only identity.
pub fn register_fork_handler() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        #[cfg(unix)]
        // SAFETY: `on_fork_child` is an `extern "C" fn()` that stays valid for
        // the life of the process (see above) and is async-signal-safe.
        unsafe {
            let _ = libc::pthread_atfork(None, None, Some(on_fork_child));
        }
    });
}

impl ProcessIdentity {
    /// This process's identity. The single `std::process::id()` call site.
    pub fn current() -> Self {
        Self {
            pid: std::process::id(),
            generation: FORK_GENERATION.load(Ordering::Relaxed),
        }
    }

    /// An identity from its two halves — ONLY for the fork-identity
    /// diagnostics in `lib.rs`, which let the specs compare identities that no
    /// real fork can produce on demand (an equal pid with another generation).
    pub fn from_parts(pid: u32, generation: u32) -> Self {
        Self { pid, generation }
    }

    /// The fork generation, for `Native.fork_generation` (a diagnostic the
    /// fork specs read; not part of the Ruby API).
    pub fn generation(self) -> u32 {
        self.generation
    }

    /// Both halves in one word, for a lock-free atomic record. `0` is never a
    /// real identity (no user process has pid 0), so it can mean "none".
    pub fn to_bits(self) -> u64 {
        (u64::from(self.pid) << 32) | u64::from(self.generation)
    }
}

// The process-wide tokio runtime, tagged with the identity of the process it
// was built under (see `ProcessIdentity`). A
// multi-threaded runtime owns worker + I/O-driver threads, and `fork(2)` copies
// ONLY the calling thread — so a child that inherits this runtime has a runtime
// whose threads are gone: `block_on` can still drive the current thread, but the
// background I/O that keeps e.g. the agent-relay connection alive never runs, so
// connections stall/drop mid-use. This is hit in practice by forking job servers
// (Solid Queue, Resque) and clustered web servers (Puma workers).
//
// The runtime and its process identity live in ONE heap cell behind ONE atomic
// pointer, so a reader sees either a whole cell or none: there is no window in
// which the pointer is new and the identity old (or the reverse), and no mutex
// that a fork could capture locked or that a panic could poison.
struct RuntimeCell {
    owner: ProcessIdentity,
    rt: Runtime,
}

static RUNTIME: AtomicPtr<RuntimeCell> = AtomicPtr::new(std::ptr::null_mut());

fn build_runtime() -> Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("microsandbox-rb")
        .build()
        .expect("microsandbox: failed to build tokio runtime")
}

/// The multi-threaded tokio runtime for THIS process, built on first use and
/// rebuilt after a `fork(2)` (see the note above).
pub fn runtime() -> &'static Runtime {
    let cur = ProcessIdentity::current();
    let mut observed = RUNTIME.load(Ordering::Acquire);
    // SAFETY (every dereference below): a non-null pointer in `RUNTIME` came
    // from `Box::into_raw` and is never freed once published, so it is valid
    // for `'static`.
    if let Some(cell) = unsafe { observed.as_ref() } {
        if cell.owner == cur {
            // Built in this process: its threads are alive here.
            return &cell.rt;
        }
    }

    // Slow path: no runtime yet, or the one we see was built by a parent
    // process. Build ours and publish it with a compare-exchange.
    let fresh = Box::into_raw(Box::new(RuntimeCell {
        owner: cur,
        rt: build_runtime(),
    }));
    loop {
        match RUNTIME.compare_exchange(observed, fresh, Ordering::AcqRel, Ordering::Acquire) {
            // Published. The cell we replaced (if any) belonged to a parent
            // process and is LEAKED on purpose, never dropped: its worker
            // threads did not survive the fork, and `Runtime`'s `Drop` joins
            // them. One runtime is leaked per forked process that uses the
            // SDK.
            Ok(_) => return unsafe { &(*fresh).rt },
            Err(winner) => {
                if let Some(cell) = unsafe { winner.as_ref() } {
                    if cell.owner == cur {
                        // Another thread of THIS process won the race. Our
                        // cell was never published and its threads are alive
                        // here, so dropping it is safe (and joins them).
                        drop(unsafe { Box::from_raw(fresh) });
                        return &cell.rt;
                    }
                }
                observed = winner;
            }
        }
    }
}

/// The Rust payload of a wrapped Ruby object, bound to the process that
/// created it.
///
/// A handle that crosses a `fork(2)` is useless in the child and dangerous to
/// destroy there: it owns tasks, channels and connections of the parent's
/// runtime, clones of the parent's backend, the parent-watchdog pipe of a
/// sandbox. So every `#[magnus::wrap]` type keeps its payload in one of these:
///
/// * [`get`](Self::get) — the only way to the payload for anything that acts
///   on it — fails with `Microsandbox::ForkedHandleError` in any process other
///   than the one that built the value. `Deref` is deliberately not
///   implemented: an access that skips the check should not compile.
/// * `Drop` runs the payload's destructor only in that same process. A forked
///   child that garbage-collects an inherited handle — at the latest when it
///   exits: Ruby frees every `T_DATA` object in `rb_objspace_call_finalizer` —
///   leaks it instead.
pub struct ForkGuarded<T> {
    owner: ProcessIdentity,
    /// The Ruby class users know the handle by, for the error message.
    class: &'static str,
    inner: ManuallyDrop<T>,
}

impl<T> ForkGuarded<T> {
    pub fn new(class: &'static str, inner: T) -> Self {
        Self {
            owner: ProcessIdentity::current(),
            class,
            inner: ManuallyDrop::new(inner),
        }
    }

    /// A guard owned by `owner` instead of this process — ONLY for the
    /// fork-identity diagnostic in `lib.rs`, which runs the real ownership
    /// decision ([`get_in`](Self::get_in)) on identities given by a spec.
    pub fn owned_by(owner: ProcessIdentity, class: &'static str, inner: T) -> Self {
        Self {
            owner,
            class,
            inner: ManuallyDrop::new(inner),
        }
    }

    /// The payload, or `ForkedHandleError` when this is not the process that
    /// created it.
    pub fn get(&self) -> Result<&T, Error> {
        self.get_in(ProcessIdentity::current())
    }

    /// [`get`](Self::get) as decided in the process identified by `cur`.
    pub fn get_in(&self, cur: ProcessIdentity) -> Result<&T, Error> {
        if self.owner == cur {
            Ok(&self.inner)
        } else {
            Err(error::forked_handle(self.class, self.owner.pid, cur.pid))
        }
    }

    /// The payload without the process check — ONLY for accessors that copy
    /// plain data out of the value's own memory (a name, an id, a cached
    /// status). Those stay readable in a forked child, which needs e.g. the
    /// name to open its own handle. Never use this for anything that takes a
    /// lock, touches a file descriptor, or reaches the runtime or the backend.
    pub fn peek(&self) -> &T {
        &self.inner
    }
}

impl<T> Drop for ForkGuarded<T> {
    fn drop(&mut self) {
        if self.owner == ProcessIdentity::current() {
            // SAFETY: dropped exactly once, here; `inner` is not used again.
            unsafe { ManuallyDrop::drop(&mut self.inner) };
        }
        // Otherwise: inherited across a fork. Leak it (see the type docs).
    }
}

/// Resolve the Ruby class of a `#[magnus::wrap]` type now, at extension load.
///
/// The `wrap` macro looks its class up lazily, the first time a value of the
/// type is handed to Ruby, with `funcall("const_get", ...)` — and a `funcall`
/// is an interrupt checkpoint (rule 2 in the module docs). Left lazy, the first
/// `Sandbox.create` of a process that an interrupt raced would hit that
/// checkpoint while the freshly booted sandbox was still a plain Rust value.
/// Every module's `define` calls this for each type it wraps, right after
/// defining the class, so wrapping a value afterwards is `TypedData::class`
/// reading a resolved static plus `rb_data_typed_object_wrap`.
///
/// Doing it at load also keeps that first resolution away from concurrent
/// callers, which matters since magnus 0.9: the static is a magnus `Lazy`, an
/// `OnceLock` whose initializer (the `const_get`) runs while holding the lock.
/// That `funcall` can switch Ruby threads, and a second thread reaching the
/// same lock would block on it while holding the GVL the first one needs to
/// finish.
pub fn preload_class<T: TypedData>(ruby: &Ruby) {
    let _ = T::class(ruby);
}

/// How often [`nogvl`] lets Ruby process interrupts before the work starts
/// until it gives up. See the comment in the loop: this is a defensive bound,
/// not a path a healthy process takes.
const MAX_ENTRY_ATTEMPTS: u32 = 64;

/// Let Ruby deliver whatever interrupts are pending for this thread, turning a
/// raised exception or any other non-local exit (e.g. the `TAG_FATAL` jump of a
/// `Thread#kill`) into an `Err` instead of letting it `longjmp` through us.
///
/// `rb_thread_check_ints` is `rb_ec_check_ints` → `RUBY_VM_CHECK_INTS_BLOCKING`
/// → `vm_check_ints_blocking` → `rb_threadptr_execute_interrupts(th, 1)`
/// (thread.c): it runs trap handlers, may switch threads on a timer tick, and
/// raises queued `Thread#raise` exceptions — with *blocking* timing, so it also
/// raises the ones a caller deferred with
/// `Thread.handle_interrupt(X => :on_blocking)`.
///
/// (All CRuby references in this file were read from the Ruby 3.4.5 sources;
/// the functions named behave the same in 3.1–3.3, the other versions this gem
/// supports.)
/// `magnus::rb_sys::protect` is `rb_protect`; magnus re-raises (or re-jumps)
/// the returned `Error` once it reaches the method boundary, after every Rust
/// frame in between has unwound normally.
fn check_interrupts() -> Result<(), Error> {
    magnus::rb_sys::protect(|| {
        // SAFETY: called on a Ruby thread holding the GVL (every caller of
        // `nogvl` is a bound method), inside `rb_protect`.
        unsafe { rb_sys::rb_thread_check_ints() };
        rb_sys::Qnil as rb_sys::VALUE
    })
    .map(|_| ())
}

/// Run `f` with the Ruby GVL released.
///
/// `f` runs on the *same* OS thread (the C call blocks until it returns), so no
/// `Send`/`'static` bound is required. `f` MUST NOT touch the Ruby C API while
/// the GVL is released. Panics are caught and re-raised after the GVL is
/// re-acquired, because unwinding across the C frame would be undefined
/// behaviour.
///
/// Returns `Err` only when `f` did NOT run: an interrupt was delivered before
/// the work started (a pending `Thread#raise`/`Thread#kill`/SIGINT), so there
/// is nothing to lose and the caller just propagates it with `?`. Once `f` has
/// run, this returns `Ok` with its value and Ruby is not consulted again.
pub fn nogvl<F, R>(f: F) -> Result<R, Error>
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
        // outlives this call (rb_thread_call_without_gvl2 blocks until return).
        let state = unsafe { &mut *(arg as *mut State<F, R>) };
        let f = state.f.take().expect("nogvl callback invoked twice");
        state.out = Some(catch_unwind(AssertUnwindSafe(f)));
        std::ptr::null_mut()
    }

    let mut state: State<F, R> = State {
        f: Some(f),
        out: None,
    };

    // Why not the plain `rb_thread_call_without_gvl`: `rb_nogvl` (thread.c)
    // ends it with `RUBY_VM_CHECK_INTS_BLOCKING(ec)` — step (5) "Check
    // interrupts" of the contract in its doc comment — AFTER the callback has
    // returned. An exception raised there leaves by `longjmp` past this frame,
    // `block_on`'s and the bound method's, with the callback's result sitting
    // in `state.out`: never returned, never dropped. That exit check is the bug
    // this function exists to avoid, so the plain call must not come back here
    // in any form, not even as a fallback.
    //
    // `rb_thread_call_without_gvl2` is `rb_nogvl(..., RB_NOGVL_INTR_FAIL)`:
    //   * at entry `unblock_function_set(.., fail_if_interrupted = 1)` returns
    //     FALSE when `RUBY_VM_INTERRUPTED_ANY(ec)` — any unmasked bit of
    //     `ec->interrupt_flag` — is set, and `BLOCKING_REGION` then skips the
    //     callback altogether;
    //   * at exit the `RUBY_VM_CHECK_INTS_BLOCKING` is skipped
    //     (`if ((flags & RB_NOGVL_INTR_FAIL) == 0)`).
    // So it never jumps, but it can decline to run. We do the checking
    // ourselves, only at points where nothing has happened yet.

    // (i) One protected check before we start. The plain call also checked at
    //     entry (`unblock_function_set` → `RUBY_VM_CHECK_INTS`), so an interrupt
    //     that is already pending keeps being delivered before any work is
    //     done. One difference, on purpose: the plain call's entry check used
    //     non-blocking timing and its EXIT check was the one that delivered
    //     exceptions deferred with `Thread.handle_interrupt(X => :on_blocking)`
    //     — i.e. at exactly the point that lost the result. This check uses
    //     blocking timing (see `check_interrupts`), so such an exception is now
    //     raised here, before the call, if it is already queued; one that
    //     arrives during the call waits for the thread's next blocking point.
    //     Nothing has happened yet, so an `Err` unwinds our frames normally and
    //     drops `f` (and the future it owns).
    check_interrupts()?;

    let mut attempts = 0;
    loop {
        // SAFETY: `call` matches the expected signature, `state` outlives the
        // call, and a null unblock function is allowed (the call is simply not
        // cancellable, as before).
        unsafe {
            rb_sys::rb_thread_call_without_gvl2(
                Some(call::<F, R>),
                &mut state as *mut _ as *mut c_void,
                None,
                std::ptr::null_mut(),
            );
        }
        if state.out.is_some() {
            // The callback ran. Do NOT check interrupts: see the invariant below.
            break;
        }

        // (ii) An interrupt bit was set at entry, so the callback did NOT run
        //      and nothing has happened. This is routine, not exotic:
        //      `RUBY_VM_INTERRUPTED_ANY` also covers the timer tick, postponed
        //      jobs and the VM barrier, and a `Thread#raise` can land in the few
        //      instructions since the check above. Let Ruby process it under
        //      protection, then retry.
        //
        //      The retry cannot spin: `rb_threadptr_execute_interrupts` loops on
        //      `threadptr_get_interrupts`, which clears every unmasked bit of
        //      `ec->interrupt_flag` (the `ATOMIC_CAS` to `interrupt &
        //      ec->interrupt_mask`) before dispatching, until none is left. That
        //      holds even when the queued exception stays masked
        //      (`handle_interrupt(X => :never)`):
        //      `rb_threadptr_pending_interrupt_deque` then returns `Qundef` and
        //      sets `pending_interrupt_queue_checked`, and although
        //      `vm_check_ints_blocking` re-sets the pending bit on each call, the
        //      same call consumes it again. We hold the GVL from the return of
        //      the check to the entry test of the next attempt, so only a
        //      non-Ruby source (timer thread, signal) can set a bit in between.
        check_interrupts()?;

        // The one case in which the bits are NOT consumed is `ec->raised_flag`:
        // `rb_threadptr_execute_interrupts` returns at once while CRuby is in
        // the middle of raising (`setup_exception` in eval.c — an overridden
        // `Exception#backtrace`, a `TracePoint` `:raise` hook). A native call
        // made from there with an interrupt pending can never start under
        // `_gvl2`. Fail it with a normal error rather than loop forever (or
        // reach for the plain call); nothing has run, so nothing is lost.
        attempts += 1;
        if attempts >= MAX_ENTRY_ATTEMPTS {
            return Err(error::base_error(
                "native call could not start: interrupt check did not settle",
            ));
        }
    }

    // INVARIANT: from here until the bound method returns its value to Ruby,
    // nothing checks interrupts (rule 2 in the module docs). The next
    // checkpoint is the Ruby VM's own, AFTER the value has become a Ruby
    // object, so the value is either returned or dropped by Rust — never
    // abandoned in this frame by a `longjmp`.
    match state.out.take() {
        Some(Ok(value)) => Ok(value),
        Some(Err(panic)) => std::panic::resume_unwind(panic),
        // Not reachable: the loop above only breaks once `state.out` is `Some`.
        // Kept as an error instead of a panic so a future edit to the loop
        // cannot turn into an abort across the FFI boundary.
        None => Err(error::base_error("native call did not run")),
    }
}

/// Drive a future to completion on the shared runtime with the GVL released.
///
/// `Err` means the future was never polled (see [`nogvl`], and the fork check
/// below); propagate it with `?` before looking at the future's own output:
/// `block_on(fut)?.map_err(error::to_ruby)?`.
pub fn block_on<F>(fut: F) -> Result<F::Output, Error>
where
    F: Future,
{
    // Many core operations resolve the process-wide default backend while they
    // run. After a fork that backend is the parent's; replace it now, while we
    // still hold the GVL (the check takes a mutex and may build a Ruby
    // exception — neither is allowed once the GVL is released).
    crate::backend::ensure_this_process_backend()?;
    nogvl(|| runtime().block_on(fut))
}
