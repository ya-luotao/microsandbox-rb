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

`block_on` is wrapped in `nogvl` (`rb_thread_call_without_gvl2`) so the Ruby
Global VM Lock is **released** while a sandbox operation is in flight. Without
this, a long-running `exec` would freeze every other Ruby thread/fiber in the
process (a real problem under Rails/Puma). The `nogvl` closure runs pure Rust
only (never touches the Ruby C API) and uses `catch_unwind` so a Rust panic is
captured and re-raised *after* the GVL is re-acquired rather than unwinding
across the C frame (which would be UB).

**The *calling* thread is not preemptible during the call.** `nogvl` passes a
null unblock-function, so while a native call blocks, the thread that issued it
cannot be interrupted: `Timeout::timeout` (which relies on `Thread#raise`),
`Thread#kill`, and `SIGINT` (Ctrl-C) are all deferred until the call returns on
its own. The GVL release keeps *other* threads live; it does **not** make the
calling thread cancelable. This is harmless for the bounded calls
(`exec`/`shell` with a `timeout:`, `AgentClient` with a `timeout:`) because the
deadline fires inside the future, but the unbounded/streaming paths —
`exec`/`shell` with `timeout: nil`, `ExecHandle#recv`/`#wait`,
`log_stream`/`metrics_stream` `recv` (especially `follow: true`),
`Sandbox#wait`/`SandboxHandle#wait_until_stopped`, and `AgentClient#request`
with no timeout — can block their caller indefinitely if the guest wedges or a
relay drops. **Bound such calls with the explicit `timeout:` knobs rather than
wrapping them in `Timeout::timeout`**, which will not fire while the native
call is in flight.

### Interrupts never lose a result

An interrupt that arrives during a native call is delivered **after the call
returns**, and the call's result is not lost. Ruby delivers `Thread#raise`,
`Thread#kill` and `SIGINT` with a `longjmp`, which skips Rust frames without
running destructors; if that happened while the value a call had just produced
(a booted sandbox, a guest exec session, megabytes of output) lived only in a
Rust frame, it would be neither returned to Ruby nor dropped. The plain
`rb_thread_call_without_gvl` does exactly that — it checks interrupts once more
after the callback, before returning — which is why it is not used. Two rules
in `runtime.rs` replace it:

1. `nogvl` checks interrupts itself, under `rb_protect`, **only before the work
   starts**: once up front, and again whenever `rb_thread_call_without_gvl2`
   declined to run the callback because an interrupt was pending at entry. A
   raise or kill there is an ordinary `Err` that unwinds the Rust frames
   normally — nothing has happened yet. After the callback has run, nothing is
   checked. (`nogvl` and `block_on` therefore return `Result`, and every call
   site propagates it with `?`. A bound method that needs two awaits does both
   in one `block_on`, so no value sits between two entry checks.)
2. Between `block_on` returning and the bound method returning its value, the
   binding does not call into Ruby: no `funcall` (the VM checks interrupts
   after every one), only C-level Hash/Array/String construction and
   `TypedData` wrapping. The class lookup magnus would otherwise do with
   `const_get` on a type's first wrap is resolved at extension load instead.

So the next interrupt checkpoint after a native call is the Ruby VM's own,
reached once the result is a Ruby object. What happens to it then:

- **`Sandbox.create`, `Sandbox.connect_or_create`, `Sandbox.start`, and
  `PullSession#sandbox`** mask interrupts (`Thread.handle_interrupt(Object =>
  :never)`) around the native call only, so the bare `Native::Sandbox` is
  bound to a local before a queued exception or kill can land; an `ensure`
  then **stops the sandbox** when one cuts in before the caller has the
  object — but only a sandbox the call owns (`owns_lifecycle`, the same
  predicate as `connect_or_create`'s block form): one that was already
  running for someone else is left running. The Ruby wrapper is constructed
  *after* the mask, with normal interrupt handling, because `new` runs a
  subclass's `initialize`: a constructor that blocks or runs long must not
  hold a `Timeout.timeout` or `Thread#kill` back until it returns. So the
  cleanup works on the native handle (its `owns_lifecycle` and `stop`), never
  on the wrapper, and covers the window from the native handle's assignment
  through the wrapper's construction: an interrupt delivered as the mask ends
  (before `new` runs), one delivered inside a subclass's `initialize`, and an
  exception that `initialize` raises itself. That cleanup is best-effort, not
  a guarantee for every lost return: a *further* interrupt that arrives during
  the cleanup itself, before the native `stop` has started, or one delivered
  at the method's final return boundary, after the wrapper has been handed
  off but before the caller has assigned it, leaves the teardown to GC (as it
  did before construction moved out of the mask). A `SIGINT` cannot be masked
  this way; it can arrive before the native handle is assigned, and then the
  next case applies.
- **Every other wrapper** (`ExecHandle`, streams, SSH clients, write sinks, …)
  and every plain result simply becomes garbage; GC frees the wrapper and the
  Rust value's `Drop` closes the session or connection.

The calls themselves remain uninterruptible, so `Timeout.timeout { Sandbox.create(...) }`
still waits for the create to finish — and now also for the stop that cleans
it up — before `Timeout::Error` surfaces. That stop is best-effort (a failure
is swallowed so the interrupt is what the caller sees; GC then tears the
sandbox down).

`Thread.handle_interrupt(X => :on_blocking)` treats a native call as the
blocking point at its *start*: the bridge raises an exception that is already
deferred before the call begins, and one that arrives during the call waits
for the thread's next blocking operation. The four acquisition methods are
the exception: their own `Object => :never` mask sits on top of the caller's,
so a deferred exception is not raised at the native call's entry there — the
sandbox is returned and the exception is delivered at the next blocking
operation after the acquisition. (If that blocking operation is inside a
subclass's `initialize`, the caller does not have the object yet, so the
sandbox is stopped as above.)

`spec/fake_runtime/interrupt_safety_spec.rb` pins all of this against the real
extension, driving it with a fake `msb` (`spec/support/fake_runtime/`) whose
log shows whether a sandbox was stopped, dropped, or left attached.

### Fork safety

`fork(2)` copies only the calling thread. A child of a process that has used
the SDK therefore inherits native state whose threads are gone: the tokio
runtime (workers, I/O driver), the core's process-wide default backend (each
SQLite connection of a `LocalBackend` is served by its own worker thread; a
`CloudBackend`'s pooled connections belong to the parent's runtime), and every
wrapped handle built on top of them. Using that state hangs or crashes — the
child's first catalog read used to wait out the pool's 30 s acquire timeout on
Linux and die with `SIGTRAP` on macOS — and so does *destroying* it, because
the destructors wake the same missing threads (on macOS, replacing an
inherited `LocalBackend` was enough to kill the child). One rule covers all of
it: **inherited native state is never used and never dropped in the child. It
is leaked, once per fork, and replaced by state built in the child.**

That needs a reliable answer to "was this built by the process I am?". The
binding's answer is a **process identity** (`runtime::ProcessIdentity`): the
pid together with a *fork generation*. At extension load the binding
registers a `pthread_atfork` child handler whose only work is one atomic
increment of a counter; the child inherits its parent's counter as plain
memory, and the handler, running in the child before `fork` returns there,
makes it one higher. `Kernel#fork` calls libc's `fork`, which runs atfork
handlers on Linux and macOS, so a child, grandchild, … of the loading process
has generation 1, 2, …, whatever its pid. Everything the binding builds is
tagged with the identity of the process that built it, and two identities
are equal only when both halves are:

- the generation tells apart a descendant that was handed an ancestor's pid
  again by the kernel (the pid counter wrapped onto exactly that value)
  without any SDK call in between — pid alone would take it for the
  ancestor;
- the pid tells apart a process created without running atfork handlers
  (`vfork`, a raw `clone`), whose generation equals its parent's.

The handler is async-signal-safe (a lock-free atomic add, no allocation, no
lock, no Ruby), as a child handler must be; `Relaxed` ordering suffices
because the forked child is single-threaded until it starts threads, which
see the counter through the spawn's own synchronization. Handlers cannot be
unregistered, and Ruby never unloads an extension, so the handler stays
valid for the life of the process. Should registration fail (`ENOMEM`), the
generation stays 0 and the identity is effectively the pid alone.
Three spec-only diagnostics on `Native` expose it: `fork_generation` returns
the counter, and `fork_identity_equal` / `fork_identity_guard` run the real
comparisons (`==`, the packed backend word, a handle's ownership check) on
identities a spec chooses — the only way to pin that both halves decide,
since a real fork changes both and pid reuse cannot be staged
(`spec/unit/fork_identity_spec.rb`).

Three pieces use the identity:

- **Runtime cell** (`runtime.rs`). The runtime and the identity of the process
  that built it live in one heap cell behind one `AtomicPtr`. `runtime()`
  returns the cell's runtime when that identity is ours; otherwise it builds a
  new cell and publishes it with a compare-exchange (a loser of that race in
  the same process drops its own, never-published runtime). There is no mutex,
  so nothing can be inherited locked or poisoned, and no window in which
  pointer and identity disagree. A cell built by a parent process is leaked:
  `Runtime`'s `Drop` joins worker threads that do not exist.
- **Backend record** (`backend.rs`). The binding records how the default
  backend was chosen — the core's own ladder (environment, profile, config
  file), or an explicit `set_default_backend`/`with_backend` selection — and
  the identity of the process it belongs to (one `AtomicU64`, pid and
  generation, written and read whole). `ensure_this_process_backend` runs,
  with the GVL held, at the start of every `block_on` and of every synchronous
  entry that reads the backend. The one exception is the runtime installer
  (`Native.install`, `Native.setup`): it never reads the backend, so it runs
  through `block_on_runtime_install`, which skips the check, and a child that
  installs leaves the record alone for its first call that does use the
  backend. In a process whose identity differs from the recorded one it
  builds a fresh backend from the record, swaps it into the core and
  `mem::forget`s the inherited one, along with the backends that open
  `with_backend` scopes had saved for their restore. A scope the parent opened
  can still be closed in the child: closing it installs a backend rebuilt from
  how the saved one had been chosen. For the ladder this means the child
  resolves it again, from its own environment, at its first native call; if
  that fails, the call raises the configuration error, nothing is changed, and
  the next call tries again. `set_default_backend` and a `with_backend` push
  are the exception: they are about to replace the default anyway, so in a
  child they take over with the backend they were asked for and never rebuild
  the inherited selection — an explicit selection always gets a child out of
  an inherited one that no longer resolves. Closing a scope works the same
  way: a child whose first use of the backend is leaving a block its parent
  entered takes over directly with what the scope restores, so it never needs
  the scope's temporary backend (which it may be unable to rebuild). Closing a
  scope always consumes it: when the backend it should restore cannot be
  rebuilt in the child, the scope's temporary selection stays in effect and
  the error is reported (by `with_backend` as a warning when the block itself
  raised, so that the block's exception is the one that propagates).
- **`ForkGuarded<T>`** (`runtime.rs`). The payload of every `#[magnus::wrap]`
  type sits in one, tagged with the identity of the creating process. `get()`
  is the only way to it for anything that acts on the value, and in another
  process it returns `Microsandbox::ForkedHandleError` (there is no `Deref`,
  so an unchecked access does not compile). The message names the creating pid
  and the current one; when they are equal — a reused pid — it says so rather
  than naming the same pid twice as two processes. Its `Drop` runs the
  payload's destructor only in the creating process; a child that
  garbage-collects an inherited handle — at the latest when it exits, since
  Ruby frees every wrapped object then — leaks it. Accessors that only copy
  plain data out of the value (`name`, `id`, the `SandboxHandle` snapshot
  fields, `ExecHandle#id`) skip the check through `peek()`, so a child can
  still read the name it needs to open a handle of its own.

What a child leaks is bounded: one runtime; once it uses the backend, the
inherited default backend and the saved backend of each open scope; each
inherited handle it collects; plus one backend for each parent-opened scope it
closes. A child that only installs the runtime builds no backend.

The mutexes involved (`backend.rs`) are only taken with the GVL held, and
nothing that runs under them calls into Ruby or releases the GVL — Ruby
exceptions are built after they are released. A Ruby-level `fork` needs the
GVL, so a child never inherits one of them locked.

Limits, by design:

- **Inherited file descriptors.** A child inherits the parent's open fds,
  including the parent-watchdog pipe of every sandbox the parent created.
  While such a child lives, the runtime sees no EOF on that pipe when the
  parent exits, so the sandbox is not torn down until the child exits too.
- **Ownership.** A sandbox created before the fork belongs to the parent. The
  child cannot act on it through the inherited handle; it can open its own by
  name, with the usual ownership rules.
- **Threads mid-call.** A thread that is inside a native call when another
  thread forks (the GVL is released there) may hold a lock in the core at
  that instant — for example the read guard of the core's default-backend
  `RwLock`, for the few instructions of an `Arc` clone — and the child's swap
  then waits on that inherited lock forever. The binding cannot close this
  window. Forking while another thread is inside a call is unsupported, as
  with any threaded native library.
- **Other libraries.** The SDK no longer touches inherited state; code that
  reaches it some other way can still hang or trap.
- **macOS system frameworks.** On macOS a forked child that has not called
  `exec` cannot use the system frameworks the core reaches for network and
  credential work: CoreFoundation and libobjc are not fork-safe, and the
  child dies — `SIGSEGV`, or `SIGABRT` from libobjc's fork check — inside the
  framework. It is a crash, not an exception; nothing can rescue it. Two such
  calls sit on SDK paths. Every HTTP client the core builds (reqwest, with the
  `system-proxy` feature that the core crate enables; a downstream crate
  cannot turn a Cargo feature off) looks up the system proxy settings through
  SystemConfiguration (`SCDynamicStoreCopyProxies`) while it is built; and a
  pull without explicit `registry_auth:` first looks for registry credentials
  in the Keychain (`keyring`). So in a forked child on macOS, each of these
  kills the child:
  - any use of a cloud backend, however it is chosen (`set_default_backend`,
    `with_backend`, `MSB_BACKEND`/`MSB_API_KEY`, a profile) — the child's
    rebuild of the backend described above builds a client;
  - `Sandbox.create` with an image that is not in the image cache yet, or
    with `pull_policy: :always` (the Keychain lookup, then the registry
    client; with `registry_auth:` only the latter);
  - `Image.load` (it builds a registry client even for a local archive);
  - runtime provisioning: `Microsandbox.install`, `Microsandbox.setup`, and
    the first-use install in `ensure_runtime!`.

  Whether the parent used the SDK makes no difference: a child of a parent
  that only required the gem dies the same way, and
  `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` does not prevent it. Calls that
  stay on the local catalog and runtime are unaffected, including
  `Sandbox.create` with an image already in the cache. On Linux the cloud
  case is exercised by `spec/unit/fork_safety_spec.rb` and works (those
  examples are skipped on macOS). On macOS, do this work in a process that
  was not forked — the parent before it forks, or a fresh one
  (`Process.spawn`, or `fork` followed by `exec`) — for example, pull the
  images the workers need in the master before forking them.
- **Forks that skip atfork handlers.** A process created with `vfork` or a
  raw `clone` keeps its parent's generation, so only its pid identifies it.
  Ruby itself never forks that way — `Kernel#fork` runs the handlers, and
  `spawn`/`system` `exec` at once, which discards all of this state — so
  mistaking such a process for its ancestor needs a native library that
  clones without the handlers and then runs Ruby, together with exact pid
  reuse.

`spec/unit/fork_safety_spec.rb` (catalog only, no runtime),
`spec/fake_runtime/fork_safety_spec.rb` (a live handle over the fake `msb`)
and `spec/integration/fork_safety_spec.rb` (a real microVM) pin the behaviour;
each forks from a probe process of its own.

## Error mapping

The core returns one big `MicrosandboxError` enum. `error.rs` maps each variant
to a Ruby exception class under `Microsandbox` (e.g. `InvalidConfig` →
`Microsandbox::InvalidConfigError`), all descending from `Microsandbox::Error`,
each carrying a stable `#code`. This mirrors `sdk/python/microsandbox/errors.py`
and the Rust→class mapping in `sdk/python/src/error.rs`.

## Runtime binary (`msb` + `libkrunfw`)

The gem is **SDK-only**: nothing is provisioned while it is built or installed.
The core crate's `prebuilt` feature — whose `build.rs` downloads the `msb`
microVM runtime and `libkrunfw` firmware into `~/.microsandbox/{bin,lib}` at
build time — is deliberately **off** (`default-features = false`, features
`keyring`/`net`/`ssh`, the set the official SDKs ship). Build-time provisioning
only ever helped the source gem: for a precompiled gem the download lands on the
CI host, and even for a source install it couples "compile a Ruby extension" to
"fetch 50 MB of host binaries", which is not the compiler's business.

The *guest* agent is a different story and is still embedded at build time: the
`agentd` binary that runs as PID 1 inside every microVM is `include_bytes!`-d
into the extension by `microsandbox-filesystem`'s `build.rs`, keyed by *target*
arch. Without its `prebuilt` feature that build script demands a locally built
`build/agentd` (workspace-only), so `ext/microsandbox/Cargo.toml` enables exactly
that one sub-feature through a direct `microsandbox-runtime` dependency
(`default-features = false, features = ["prebuilt"]`, whose `prebuilt` is just
`microsandbox-filesystem/prebuilt`) while the SDK-level host download stays off.

### The companion gem

The host runtime ships as its own gem, **`microsandbox-rb-binaries`** (source in
`binaries/`), one platform gem per `arm64-darwin` / `x86_64-linux-gnu` /
`aarch64-linux-gnu` (Linux binaries are glibc-linked, hence
`required_rubygems_version >= 3.3.11`). It carries `vendor/bin/msb`,
`vendor/lib/libkrunfw.*` and a `vendor/manifest.json` — a layout that mirrors
both the upstream release bundle and `~/.microsandbox`, so the core finds the
firmware by `../lib` adjacency to `msb` and only the binary path needs handing
over (same trick as the Python and Node SDKs). Everything is downloaded from the
upstream GitHub release named by `Microsandbox::Binaries::RUNTIME_VERSION` and
sha256-verified fail-closed against that release's `checksums.sha256` — the copy
committed as `binaries/checksums/<tag>.sha256` when the runtime was adopted
(a GitHub release is mutable, so the live file must agree with the reviewed
one, not replace it) — at vendoring time; the gem build re-verifies the staged
tree against the manifest (regular files only), so nothing unverified is ever
packaged. Build pipeline:
`rake -C binaries vendor[<platform>] build[<platform>] verify`.

There is **no dependency edge in either direction**. RubyGems has no optional
dependencies, and cloud-only users (`MSB_BACKEND=cloud`) must not be forced to
download ~50 MB of binaries they will never execute — so the SDK discovers the
companion gem instead of depending on it, and the companion gem stays a pure
payload. The two are versioned in lockstep (`Binaries::VERSION` ==
`Microsandbox::VERSION`, `Binaries::RUNTIME_VERSION` == `RUNTIME_VERSION`, both
asserted by `spec/unit/version_spec.rb`).

### Activation and the resolver ladder

`lib/microsandbox.rb` runs a private `activate_bundled_runtime!` once, at
`require "microsandbox"` time: `gem "microsandbox-rb-binaries", "= VERSION"`
(pins the lockstep version when RubyGems, not Bundler, picks the gem; a failure
here is tolerated) → `require "microsandbox/binaries"` (`LoadError` → the tier is
simply absent, silently) → `Binaries::VERSION` must equal `VERSION` and
`Binaries::RUNTIME_VERSION` must equal `RUNTIME_VERSION` (the `gem` pin above
cannot enforce lockstep: under Bundler it raises whenever the bundle picked any
other version, and that is swallowed) **and** both `msb_path` and
`libkrunfw_path` must exist →
`Native.set_runtime_msb_path(msb)`. The version gate is the load-bearing part: a
runtime from a different upstream release passes any exists-check and then fails
every `create` on a wire-protocol mismatch, so a mismatch is reported with a
warning and skipped rather than handed to the core. The whole path is
non-raising — a broken companion gem must never take `require "microsandbox"`
down with it.

Activation is **eager** rather than lazy, mirroring the Node SDK (`napi.ts`
pushes its platform package's `msb` into the same set-once slot at module load).
A lazy hook inside `ensure_runtime!` would only cover `Sandbox.create`/`start`
and silently miss every other entry point that resolves or spawns `msb`.

The resolver order is therefore: `$MSB_PATH` → SDK-set path (claimed by the
companion gem at load; `Microsandbox.runtime_path=` targets this same set-once
slot, so with the gem installed the setter is a **no-op** — override via
`MSB_PATH`) → config file → workspace build → `~/.microsandbox/bin/msb` →
`which msb`. `Microsandbox.runtime_path` reports the winner.
`Microsandbox.install` / `.installed?` expose the core `setup::install`/
`is_installed` for explicit, idempotent provisioning (mirrors the Python
`install()`/`is_installed()`).

Auto-provisioning stays as the **lowest tier**, deliberately (npx-style
first-use download; see upstream discussion
[superradcompany/microsandbox#1305](https://github.com/superradcompany/microsandbox/issues/1305)):
`Sandbox.create`/`start` call `Microsandbox.ensure_runtime!`, which fetches a
missing or version-stale runtime into `~/.microsandbox` on first use — by the
*running* host's arch, which is always correct — at most once per process.
`MICROSANDBOX_NO_AUTO_INSTALL` opts out (air-gapped hosts that provision out of
band). When the companion gem won the resolver (`bundled_runtime_active?`),
`ensure_runtime!` returns immediately: those binaries are already the matching
version, so nothing is downloaded or touched in `~/.microsandbox`. Note the
asymmetry in trust: the companion gem's payload is digest-verified when it is
vendored, while the first-use download is not yet content-verified (pending
upstream
[superradcompany/microsandbox#1300](https://github.com/superradcompany/microsandbox/issues/1300)).

libkrunfw is `dlopen`'d by `msb` at runtime and is never linked into the
extension.

## Core-crate dependency (self-contained)

`ext/microsandbox/Cargo.toml` depends on the core crate via a **pinned git tag**
(`microsandbox` / `microsandbox-network`, pinned to the same tag as
`Microsandbox::RUNTIME_VERSION` — currently `v0.6.18`), so the gem builds anywhere
— CI and end-user source installs —
without an adjacent checkout. For fast local development against a sibling
microsandbox checkout, copy `.cargo/config.toml.example` to `.cargo/config.toml`
(gitignored); its `paths` override builds against the local crates instead of
git. The override must never be committed — it would break container builds.

## Packaging & releases

* **Source gem**: compiles the extension via `extconf.rb` (rb-sys
  `create_rust_makefile`); requires a Rust toolchain (MSRV below).
* **Precompiled platform gems**: not built or published. Every platform
  installs the source gem, which compiles the extension via `rb_sys` at install
  time; the host runtime comes from the `microsandbox-rb-binaries` gem — or,
  without it, is fetched on first use (see above). The companion binaries gems
  below are unaffected. See [docs/releasing.md](docs/releasing.md).
* **Runtime binaries gems** (`microsandbox-rb-binaries`): a distinct artifact
  from the SDK gem — no Ruby code beyond a small
  locator module, just the verified upstream `msb` + `libkrunfw` for one
  platform. CI's `binaries` job vendors and builds all three platforms on every
  run and smoke-tests the host one; the `package` job installs the source gem
  together with the host binaries gem and asserts `Microsandbox.runtime_path`
  resolves into it, and the real-microVM integration job runs twice — once
  against a `~/.microsandbox` provision (the fallback tier) and once booting from
  the gem's vendored runtime. Publishing them is a follow-up (it needs a pending
  trusted publisher on rubygems.org) and lands with the next release.

## Build requirements

* Ruby >= 3.1, RubyGems >= 3.3.11
* Rust (stable) >= 1.91 — the core crate is edition 2024 and pulls `smoltcp`
  which sets MSRV 1.91. `rust-toolchain.toml` pins `stable`.
* Linux with KVM, or macOS on Apple Silicon (same as the other SDKs).

## Implemented surface (v1) vs roadmap

The authoritative, up-to-date scope statement — every implemented API family,
the full create-option list, and the handful of upstream knobs not yet exposed —
lives in [docs/surface.md](docs/surface.md), with the typed counterpart in
`sig/microsandbox.rbs`. It is maintained there (and only there) so this file
and the README cannot drift from each other.

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
upstream-gated — they exist at the pinned runtime,
`Microsandbox::RUNTIME_VERSION`): per-published-port host
**bind address** (ports always bind loopback), network **interface overrides**,
and inline **named-volume create-mode** (pre-create with `Volume.create`, then
mount with `{ named: }`). These slot in module-by-module exactly as the existing
bindings do. Beyond those, surfacing genuinely newer core features is gated on
advancing the pinned core-crate tag.
