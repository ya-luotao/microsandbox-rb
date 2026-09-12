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
Microsandbox.with_backend(:local) { Microsandbox::Sandbox.create("box", image: "alpine") { |sb| ... } }
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

## Environment variables

| Variable | Effect |
|----------|--------|
| `MSB_PATH` | Path to the `msb` runtime binary; outranks every other source, including the binaries gem |
| `MSB_BACKEND` | `local` or `cloud`; cloud additionally reads `MSB_API_URL` / `MSB_API_KEY` |
| `MSB_PROFILE` | Select a named profile from the config file |
| `MSB_CONFIG_PATH` | Override the `~/.microsandbox/config.json` location |
| `MICROSANDBOX_NO_AUTO_INSTALL` | Disable the first-use runtime download |
| `MICROSANDBOX_INTEGRATION` | Set to `1` to run the integration specs (development only) |
| `MICROSANDBOX_TEST_IMAGE` | Override the integration-spec image (development only) |
