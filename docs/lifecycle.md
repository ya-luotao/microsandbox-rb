# Sandbox lifecycle

`Sandbox.create` boots a microVM and returns a live `Microsandbox::Sandbox`.
`Sandbox.get`/`Sandbox.list` return a controllable `Microsandbox::SandboxHandle`
for sandboxes that already exist. The live object owns the coarse controls
(`stop`/`kill`/`drain`/`wait`); the handle owns the fine-grained ones
(`stop_with_timeout`, `request_*`, `wait_until_stopped`, `config`, `snapshot`).

## Create, stop, inspect

Stopping is not removing. The block form **stops** the sandbox when the block
returns; the stopped sandbox keeps its name, its saved configuration and its
disk state in the catalog until you remove it, and creating another sandbox
with the same name raises `SandboxAlreadyExistsError`. Three ways to finish:

- `ephemeral: true` at create — removed as soon as it stops; right for one-off
  work and for code that runs repeatedly under a fixed name.
- `sb.destroy` (or `Sandbox.remove(name)` once stopped) — remove explicitly.
- Leave it stopped and bring it back later with `Sandbox.start(name)`.

Block forms used in a loop without one of the first two accumulate stopped
sandboxes (and their disk usage) indefinitely.

```ruby
# Block form — recommended; stops the sandbox automatically (even on error)
Microsandbox::Sandbox.create("box", image: "public.ecr.aws/docker/library/alpine:latest") do |sb|
  # ...
end

# Manual form — you are responsible for stopping it
sb = Microsandbox::Sandbox.create("box", image: "public.ecr.aws/docker/library/alpine:latest")
begin
  # ...
ensure
  sb.stop          # graceful; waits without a deadline (never escalates)
  # sb.stop_with_timeout(10) # graceful within 10s, else StopTimeoutError (no kill)
  # sb.stop_and_wait # graceful, then wait → ExitStatus(#exit_code, #success?)
  # sb.kill          # force; then waits up to 5s to see it stopped
  # sb.kill_with_timeout(10) # force; one 10s bound over the whole call
  # sb.drain         # graceful drain
end

# Inspect / manage existing sandboxes. `list` returns a cursor-paginated,
# Enumerable SandboxPage of handles.
Microsandbox::Sandbox.list            # => Microsandbox::SandboxPage (first page)
Microsandbox::Sandbox.list.map(&:name)  # enumerate the page's handles
# next page: Sandbox.list_with(cursor: page.next_cursor, limit: 50)
h = Microsandbox::Sandbox.get("box")  # => Microsandbox::SandboxHandle
h.status                              # :running, :stopped, :created, ...
h.stop_with_timeout(5)                # graceful within 5s, else StopTimeoutError
h.request_stop                        # fire-and-return; pair with #wait_until_stopped
h.request_kill
h.request_drain
h.wait_until_stopped                  # => Microsandbox::SandboxStopResult
Microsandbox::Sandbox.start("box")    # restart a stopped sandbox
Microsandbox::Sandbox.remove("box")   # remove a stopped sandbox
```

`Sandbox.create` is strictly boot-only: it never runs the image's
`ENTRYPOINT`/`CMD`. See [execution.md](execution.md#default-workload) for
`exec_default`.

### Timeouts and interrupts around a create

A create cannot be interrupted while it runs, so `Timeout.timeout(5) {
Sandbox.create(...) }` does not return after 5 seconds: `Timeout::Error` is
raised only once the create has finished. When that happens the sandbox is
**stopped before the exception reaches you** — the call returns only after the
create *and* that cleanup stop have completed, so it takes longer than the
create alone — and nothing is left running without an owner. The same holds
for `Thread#raise` and `Thread#kill`, and for `Sandbox.connect_or_create`,
`Sandbox.start` and `PullSession#sandbox`. Two details:

- The sandbox is stopped, not removed. Like any stopped sandbox it keeps its
  name until you `Sandbox.remove` it (or pass `ephemeral: true`), so retrying
  the create under the same name raises `SandboxAlreadyExistsError`.
- Only a sandbox the interrupted call owns is stopped. `connect_or_create`
  that merely connected to a sandbox already running for someone else leaves
  it running, exactly as its block form does.

The cleanup stop is best-effort and bounded like a block form's (below): if
it fails, the interrupt is still the exception you get, and the sandbox is
torn down when its now unreferenced object is garbage-collected.

A Ctrl-C (`SIGINT`) is the one interrupt that cannot be held back until the
sandbox is in your hands: one that lands during the create is raised the
moment the create returns, before anything can stop the sandbox, which is then
torn down when the unreferenced object is garbage-collected instead of
immediately.

These methods hold queued interrupts back while they acquire the sandbox, so
an exception you deferred with `Thread.handle_interrupt(X => :on_blocking)` is
not raised by them: you get the sandbox, and the exception arrives at the
thread's next blocking operation.

### Stopping since runtime `v0.7`

A graceful stop no longer escalates to a kill. `#stop` sends the shutdown
request and waits, without a deadline, until the runtime has released the
sandbox. `#stop_with_timeout(n)` waits at most `n` seconds and then raises
`Microsandbox::StopTimeoutError` — it kills nothing, and the shutdown may still
complete later (a zero budget times out before the request is sent). The
budget covers the whole call, including waiting for the sandbox's transition
lock while another lifecycle operation on the same name holds it.

End it for sure with `#kill`. `#kill` first waits, **without a deadline**, for
that transition lock, then sends the kill and waits up to 5 seconds to see the
sandbox stopped. `#kill_with_timeout(n)` puts one budget of `n` seconds over
all of it, lock included, and raises `Microsandbox::Error` when it runs out
(the sandbox may then still be running). `restart`/`destroy` take a graceful
budget in `timeout:` (10 seconds by default) and raise `StopTimeoutError` when
it runs out, unless `force: true`.

The block forms of `create`, `connect_or_create` and `restore` stop the sandbox
on exit with a budget of `Microsandbox::Sandbox::BLOCK_STOP_TIMEOUT` (10)
seconds and, when that runs out, kill it with a further 15-second budget; both
cover the transition lock, so leaving a block takes at most about 25 seconds
even when a guest does not shut down or another process holds the lock.
Errors in that teardown are swallowed (the block's own result or exception
wins). When the kill fails or runs out of time, the SDK warns once on
`$stderr` — `cleanup gave up on sandbox "<name>", which may still be running`
— and leaves the sandbox as it is: stop or kill it yourself later.

```ruby
begin
  sb.stop_with_timeout(10)
rescue Microsandbox::StopTimeoutError
  sb.kill
end
```

`create(replace: true)` does not follow this model: it still escalates. When
the name belongs to a running sandbox it sends `TERM`, waits the replacement
grace (`replace_with_timeout:`, 10 seconds by default; `0` skips the `TERM`),
sends `KILL`, and gives the runtime 5 seconds to prove it exited. If it has
not, the create raises `Microsandbox::SandboxStillRunningError` rather than
reusing the name; it raises the same when an untracked runtime endpoint may
still be live, and a signal that fails raises its own error. None of this
involves `stop_with_timeout` or `Snapshot.create`'s `force:`.

## Convergent lifecycle

Idempotent operations that take a name to the state you want, whatever state
it is in now (runtime `v0.6.16`):

```ruby
# Create it, or connect to (and start) the one that is already there. The
# keyword options are `create`'s and apply only when a create actually happens.
sb = Microsandbox::Sandbox.connect_or_create("box", image: "public.ecr.aws/docker/library/alpine:latest")

sb.id                     # opaque identity of the *persisted* sandbox — unlike
                          # the reusable name, it changes on remove+recreate
sb.wait_for_status(:running)  # => SandboxHandle (no built-in timeout)
sb = sb.restart               # stop + start; => a new live Sandbox
sb.destroy                    # stop + remove, in one step

h = Microsandbox::Sandbox.get("box")
h.connect_or_start        # connect if running, start if not => Sandbox
h.restart(force: true, timeout: 5)
h.destroy
```

Everything that acts on an *existing* receiver — `wait_for_status`, `restart`,
`destroy`, `connect_or_start` — compares the identity it was bound to against
the name's current owner first, raising `Microsandbox::SandboxReplacedError`
rather than touching a sandbox someone else recreated under the same name.
(`connect_or_create` is the entry point, so it has no prior identity to check:
it simply converges on whichever sandbox now owns the name.)

`connect_or_create`'s block form stops the sandbox only when the call owns its
lifecycle — i.e. when it created it attached. A sandbox it merely connected to,
or started with `detached: true`, is left running. And the stop it does issue is
scoped to that sandbox's `id`, so a name removed and recreated while the block
ran cannot be taken down by the teardown either. `Sandbox#owns_lifecycle?`
reports which case you are in; `Sandbox#detach` hands the VM off so it
outlives the block.

## Restoring from a snapshot

`Sandbox.restore(snapshot, name:)` boots a new sandbox from a snapshot (it
replaced 0.17's `create(from_snapshot:)`). The block form stops it on exit,
like `create`'s. Without a block it keeps running after your process exits:
upstream restores **detached**, so `#owns_lifecycle?` is `false` and nothing
stops it for you. Stop it with `#stop`/`#destroy`, or bound it with
`max_duration:`/`idle_timeout:`.

```ruby
info = Microsandbox::Snapshot.create("base", from_sandbox: "worker")
Microsandbox::Sandbox.restore(info, name: "replay") { |sb| sb.shell("make test") }
```

Selectors, destination options and mount bindings are covered in
[images.md](images.md#restoring-a-snapshot).

## Upgrading sandboxes created before 0.18.0

Runtime `v0.7` keeps a sandbox's disks in a protected storage layout. A
sandbox created by 0.17.x or earlier still has the old layout, and it is
moved into the new one before its first start under 0.18.0:

- **Linux**: automatically, when the sandbox next starts.
- **macOS**: not automatically. The start raises `Microsandbox::Error`
  ("macOS legacy storage requires explicit maintenance recovery …"). Stop every pre-0.18 VM in every runtime
  home first (old full snapshots can leave writers behind in another home),
  make sure no older tool will start one or write to this storage, then
  recover each stopped sandbox:

```ruby
Microsandbox::Sandbox.recover_storage("worker", legacy_writers_stopped: true)
# => #<Microsandbox::StorageRecovery name="worker" ready=true>
```

`legacy_writers_stopped: true` is your confirmation of that maintenance
window; the runtime cannot check it from one home's catalog, so it never
assumes it. Recovery does not boot the sandbox, and it keeps the original
disks (`#originals_retained?`). The sandbox must be stopped
(`SandboxStillRunningError` otherwise). Sandboxes created under 0.18.0, and
ones already migrated, need none of this.

To see where each sandbox stands first, `Microsandbox.diagnose_storage`
inspects the local runtime home without starting, stopping, repairing or
migrating anything — including a home that only 0.17.x has opened so far:

```ruby
report = Microsandbox.diagnose_storage(all_sandboxes: true)   # or names: ["worker"]
report.sandboxes.each { |s| puts "#{s.name}: #{s.status} #{s.reason}" }
```

| `status` | Meaning |
|---|---|
| `:ready` | already in the protected layout |
| `:eligible` | Linux: migrates on its next start |
| `:maintenance_required` | macOS: run `recover_storage(legacy_writers_stopped: true)` |
| `:recovery_required` | the old metadata is ambiguous or damaged: pick a view (below) |
| `:in_progress` | an interrupted migration; `recover_storage` resumes it |
| `:unavailable` | the check could not finish; `reason` says why (`:not_found`, `:invalid_configuration`, `:incomplete_creation`, `:storage_unavailable`) |

A sandbox whose report has a `running?` VM gets a provisional answer, and a
recovery revalidates everything under locks anyway. For `:recovery_required`,
`inspection.candidates` lists the complete disk views found: choose one per
disk and acknowledge that it may lack later writes:

```ruby
candidate = report.sandboxes.first.inspection.candidates.first
Microsandbox::Sandbox.recover_storage("worker",
  selections: { candidate.disk_id => candidate.id }, accept_selected_view: true,
  legacy_writers_stopped: true)   # macOS
```

Both calls are local-only and read the runtime home that `MSB_HOME` (or
`diagnose_storage(home:)`) names; a home with no catalog yet raises
`IoError`. `recover_storage` checks the runtime first, like a start.

## The live `Sandbox` / `SandboxHandle` split

Upstream `v0.5.8` split the lifecycle into the live `Sandbox` and a
controllable `SandboxHandle`, and the gem mirrors it. The live
`Sandbox#stop`/`#kill` do not take a `timeout:`; `#request_stop`/
`#request_kill`/`#request_drain`/`#wait_until_stopped` and a custom stop timeout
live on the `SandboxHandle` from `Sandbox.get`. `Sandbox.get`/`.list` return a
`SandboxHandle` (formerly a read-only `SandboxInfo`, kept as a deprecated
alias).

`SandboxHandle` also carries `#ping`/`#touch`/`#modify` — see
[observability.md](observability.md).
