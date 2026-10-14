# Runtime binaries, resolution, and backends

## The runtime binaries

`microsandbox-rb` is **SDK-only** — it wraps the microVM runtime, it doesn't
carry it. The host-side `msb` runtime and the `libkrunfw` firmware come from an
optional companion gem, **`microsandbox-rb-binaries`**, published as one gem per
platform (`arm64-darwin`, `x86_64-linux-gnu`, `aarch64-linux-gnu`) and
versioned in lockstep with this gem:

```ruby
# Gemfile — install both gems at the same version
gem "microsandbox-rb", require: "microsandbox"
gem "microsandbox-rb-binaries"
```

That's all the wiring there is: `require "microsandbox"` finds the companion
gem, checks it is the same version and built for the same upstream runtime, and
points the resolver at its vendored `msb` — so your bundle carries the runtime
and nothing is downloaded at install time or on first call. **Recommended
whenever you boot local microVMs.** Cloud-only users (`MSB_BACKEND=cloud`)
should skip it: it is a separate, optional gem precisely so nobody has to fetch
~50 MB of binaries they won't run. Neither gem depends on the other.

> **Availability.** The binaries gems are published on every release tag
> alongside `microsandbox-rb` since `0.14.0`. On an older SDK version, or a
> platform without a bundle, use the fallback below (or build them yourself
> from `binaries/` — see [binaries/README.md](https://github.com/ya-luotao/microsandbox-rb/blob/main/binaries/README.md)).

### Fallback — first-use download

Without the companion gem, the `msb` runtime and `libkrunfw` firmware are
provisioned into `~/.microsandbox` automatically on first use (the first
`Sandbox.create`/`start` downloads them if missing). To provision ahead of time
— e.g. while baking a container image, or to avoid the first-call latency —
call `install` explicitly:

```ruby
Microsandbox.install unless Microsandbox.installed?
```

Set `MICROSANDBOX_NO_AUTO_INSTALL` to disable the automatic first-use download
(e.g. on air-gapped hosts that provision the runtime out of band). None of this
applies when the companion gem supplies the runtime: its binaries are already
the matching version, so `ensure_runtime!` skips the installer entirely and
nothing is written to `~/.microsandbox`. `Microsandbox.setup` customizes the
provisioning step itself.

## Runtime path resolution

The `msb` runtime path is resolved in this order: the `MSB_PATH` environment
variable → the `microsandbox-rb-binaries` gem (or another SDK-set override) →
the config file → `~/.microsandbox/bin/msb` → `msb` on `PATH`.
`Microsandbox.runtime_path` reports the winner.

```ruby
Microsandbox.installed?            # => true/false
Microsandbox.install               # download + install the runtime (idempotent)
Microsandbox.runtime_path          # => "/Users/you/.microsandbox/bin/msb"
Microsandbox.runtime_path = "/opt/microsandbox/bin/msb"  # override (set-once)
Microsandbox.libkrunfw_path = "/opt/microsandbox/lib/libkrunfw.dylib"  # override (set-once)
```

When `microsandbox-rb-binaries` is installed, `require "microsandbox"` claims
that SDK-set slot with the gem's vendored `msb` (the firmware is found alongside
it), and `runtime_path` points into the gem. The two gems are versioned in
lockstep and the companion gem must be the same version **and** built for the
same upstream runtime — a mismatch of either is reported with a warning and
skipped, and the SDK falls back to `~/.microsandbox` rather than driving a
runtime it doesn't match. Because the slot is **set-once**,
`Microsandbox.runtime_path=` is then a no-op: use the `MSB_PATH` environment
variable, which outranks it, to point at a different runtime.

## Backend routing

Every operation runs through a backend. The default is the local libkrun
backend; without any configuration nothing changes. A backend can be selected
programmatically or via the environment:

```ruby
Microsandbox.default_backend_kind          # => :local (or :cloud)
Microsandbox.default_backend_info          # => Microsandbox::BackendInfo
Microsandbox.set_default_backend(:cloud, url: "https://api.example.com", api_key: ENV["MSB_API_KEY"])
# or a named profile from ~/.microsandbox/config.json:
Microsandbox.set_default_backend(:cloud, profile: "prod")

# Scoped override (restored afterward, even on error):
Microsandbox.with_backend(:local) do
  Microsandbox::Sandbox.create("box", image: "alpine") { |sb| puts sb.shell("uname -a").stdout }
end
```

Resolution order when no backend is set programmatically: `MSB_BACKEND`
(`local`/`cloud`) → `MSB_PROFILE` → the `active_profile` in
`~/.microsandbox/config.json` (path overridable via `MSB_CONFIG_PATH`) →
local. **Cloud intent must be explicit** (since runtime `v0.6.9`): a bare
`MSB_API_KEY` is treated as credential material, not backend intent, and no
longer selects the cloud on its own — pair it with `MSB_BACKEND=cloud` (which
reads `MSB_API_URL`/`MSB_API_KEY`), or select a cloud profile. Invalid cloud
configuration (e.g. `MSB_BACKEND=cloud` without a usable API key or cloud
profile) fails closed with `Microsandbox::InvalidConfigError` instead of
silently running locally. The cloud backend currently supports a subset of
operations (create/start/stop/remove/get/list, one-shot exec, follow log
streaming); unsupported operations raise `Microsandbox::UnsupportedError`
(with `#operation` and `#hint`).

## Forking (Puma, Resque, Solid Queue)

Forking a process that has already used the SDK is supported: preload the
application, use the SDK in the master, fork workers, use it in the workers.
The first SDK call in a child sets up its own runtime threads and its own
backend (a new catalog connection pool, or a new HTTP client for the cloud
backend), chosen the same way as the parent's: an explicit
`set_default_backend`, an enclosing `with_backend` block, or — when neither
was used — the environment and config file as the child sees them at that
call. Everything addressed by name works in the child from then on:
`Sandbox.create`/`get`/`list`/`start`, `Volume`, `Image`, `Snapshot` — except
that on macOS a forked child must not do anything that builds a network
client (see [macOS](#macos-no-network-clients-in-a-forked-child) below).

If the parent's choice cannot be made again in the child (say the child's
environment now selects the cloud backend without credentials), SDK calls
there raise the configuration error until that is repaired. Selecting a
backend in the child — `set_default_backend`, or entering `with_backend` —
does not depend on the inherited choice and works regardless.

```ruby
Microsandbox::Sandbox.list             # the parent has used the SDK

pid = fork do
  # On macOS "alpine" must already be in the image cache (see below).
  Microsandbox::Sandbox.create("job-#{Process.pid}", image: "alpine") do |sb|
    puts sb.exec("echo", ["hello from the worker"]).stdout
  end
end
Process.wait(pid)
```

What does **not** cross a fork is an object created before it. A `Sandbox`,
`SandboxHandle`, `ExecHandle`, `ExecStdin`, `PullSession`, log/metrics/file
stream, `SshClient`/`SftpClient`/`SshServer`, `AgentClient` or `VolumeFs`
belongs to the process that created it. In a forked child, any call that acts
on one raises `Microsandbox::ForkedHandleError` (the message names both
pids); the original keeps working in the parent. Reading `name` or `id` — and
the snapshot fields of a `SandboxHandle` — still works, so a child can open
its own handle:

```ruby
sandbox = Microsandbox::Sandbox.create("shared", image: "alpine")

pid = fork do
  begin
    sandbox.exec("true")                 # the parent's handle
  rescue Microsandbox::ForkedHandleError => e
    warn e.message
  end
  mine = Microsandbox::Sandbox.get(sandbox.name).connect_or_start
  puts mine.exec("echo", ["hello"]).stdout
end
Process.wait(pid)
sandbox.stop
```

Things to know:

- **Cleanup code inherited by the child.** The block forms
  (`Sandbox.create(...) { }`, `connect_or_create`) swallow the
  `ForkedHandleError` their teardown hits when a forked child leaves the
  block, so the child does not stop the parent's sandbox. An `ensure
  sandbox.stop` of your own raises it in the child; rescue it there, or run
  the cleanup only in the process that created the sandbox.
- **Leaving a `with_backend` block in the child.** When the backend to
  restore was the parent's — the child was forked inside the block, or the
  block is the child's first use of the SDK — leaving the block installs a
  backend chosen the way that one had been. The block's own temporary backend
  is not needed for that: if only it can no longer be chosen in the child (a
  cloud profile that is gone there), leaving the block still restores the
  previous backend. If the choice to restore no longer resolves in the child,
  the block is closed anyway and its temporary selection stays in effect.
  `with_backend` then raises the configuration error — unless the block
  itself raised, in which case the block's exception propagates and the
  restore failure is reported as a warning.
- **A child keeps the parent's sandboxes alive.** A child inherits the
  parent's open file descriptors, among them the pipe through which a sandbox
  notices that its owner is gone. If the parent exits while such a child is
  still running, the sandbox is not torn down until that child exits as well.
  Fork before creating sandboxes, or create them in the children.
- **Do not fork while another thread is inside an SDK call.** That thread
  does not exist in the child, and a lock it held at that instant stays
  locked there.
- **Memory.** A child leaks, once, the native state it inherited (the
  parent's runtime, backend and whichever inherited handles it collects)
  instead of destroying it — destroying it is what used to crash.

### macOS: no network clients in a forked child

On macOS, a forked child that has not called `exec` dies — `SIGSEGV` or
`SIGABRT`, not an exception, so it cannot be rescued — as soon as the SDK
builds a network client or reads registry credentials from the Keychain
there. macOS's system frameworks do not support being used after `fork`
without `exec`, and every HTTP client the SDK builds looks up the system proxy
settings through them. In a forked child on macOS, do not:

- use a cloud backend at all, however it is selected (`set_default_backend`,
  `with_backend`, `MSB_BACKEND`/`MSB_API_KEY`, a profile);
- `Sandbox.create` with an image that is not in the image cache yet, or with
  `pull_policy: :always`;
- `Image.load`;
- install the runtime: `Microsandbox.install`, `Microsandbox.setup`, or the
  first-use install `ensure_runtime!` performs.

It makes no difference whether the parent used the SDK, and
`OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` does not help. Local work is
unaffected, including `Sandbox.create` with an image that is already cached.
On Linux the cloud backend works in a forked child.

Do that work in a process that was not forked: in the parent before it forks
(install the runtime and pull the images the workers will use — creating a
sandbox from the image pulls it), or in a fresh process started with
`Process.spawn` (or `fork` followed by `exec`).

## One runtime line per home

The runtime home (`MSB_HOME`, default `~/.microsandbox`) belongs to one
runtime line at a time. This gem embeds runtime `v0.6.18` and, on first use,
installs that version of `msb` into the home — replacing a different version
that is already there, including a newer `msb` installed by the official CLI.
In the other direction, a `0.7.x` `msb` migrates the catalog to a newer schema
the first time it opens it, after which every local call from this gem fails
with `database schema is newer than this msb binary`. The migration is one-way.

If the official CLI (or another SDK) on a different runtime line shares the
machine, give this gem its own home:

```sh
export MSB_HOME="$HOME/.microsandbox-rb"
```

## Known issues at the pinned runtime

These are fixed upstream in runtime releases this gem has not adopted yet. See
[SECURITY.md](../SECURITY.md) for the security advisories.

- **macOS hosts: guest `fallocate` can truncate a file on a bind mount or a
  directory-backed named volume.** Preallocating a range that ends inside an
  existing file shrinks the file to the end of that range, and the call
  reports success. Fixed upstream in `v0.7.0`. Until then, keep data that
  guest programs preallocate (databases, download tools) on the guest's OCI
  root disk or a `disk:` volume, not on a host directory.
- **`modify(secrets:)` adding the first secret** to a sandbox created without
  any does not turn on TLS interception, so the value is not substituted.
  Create the sandbox with at least one secret.
- **`patches:`** resets the owner and mode of parent directories that already
  exist in the image to `root:root 0755`. Write after boot with `sb.fs`, or
  restore ownership yourself.

## Environment variables

| Variable | Effect |
|----------|--------|
| `MSB_PATH` | Path to the `msb` runtime binary; outranks every other source, including the binaries gem |
| `MSB_LIBKRUNFW_PATH` | Path to the `libkrunfw` shared library; outranks `Microsandbox.libkrunfw_path=` |
| `MSB_HOME` | Runtime home: the catalog, image cache, sandboxes, volumes, snapshots, and the first-use runtime install. Default `~/.microsandbox` |
| `MSB_BACKEND` | `local` or `cloud`; cloud additionally reads `MSB_API_URL` / `MSB_API_KEY` |
| `MSB_PROFILE` | Select a named profile from the config file |
| `MSB_CONFIG_PATH` | Override the `~/.microsandbox/config.json` location |
| `MICROSANDBOX_NO_AUTO_INSTALL` | Disable the first-use runtime download |
| `MICROSANDBOX_INTEGRATION` | Set to `1` to run the integration specs (development only) |
| `MICROSANDBOX_TEST_IMAGE` | Override the integration-spec image (development only) |
