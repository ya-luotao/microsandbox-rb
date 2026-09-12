# Sandbox lifecycle

`Sandbox.create` boots a microVM and returns a live `Microsandbox::Sandbox`.
`Sandbox.get`/`Sandbox.list` return a controllable `Microsandbox::SandboxHandle`
for sandboxes that already exist. The live object owns the coarse controls
(`stop`/`kill`/`drain`/`wait`); the handle owns the fine-grained ones
(`stop_with_timeout`, `request_*`, `wait_until_stopped`, `config`, `snapshot`).

## Create, stop, inspect

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
  sb.stop          # graceful (SIGTERM→SIGKILL escalation, 10s default)
  # sb.stop_and_wait # graceful, then wait → ExitStatus(#exit_code, #success?)
  # sb.kill          # force (SIGKILL); sb.drain for a graceful drain
end

# Inspect / manage existing sandboxes. `list` returns a cursor-paginated,
# Enumerable SandboxPage of handles.
Microsandbox::Sandbox.list            # => Microsandbox::SandboxPage (first page)
Microsandbox::Sandbox.list.map(&:name)  # enumerate the page's handles
# next page: Sandbox.list_with(cursor: page.next_cursor, limit: 50)
h = Microsandbox::Sandbox.get("box")  # => Microsandbox::SandboxHandle
h.status                              # :running, :stopped, :created, ...
h.stop_with_timeout(5)                # custom escalation timeout
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
