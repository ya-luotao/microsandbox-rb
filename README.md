# microsandbox-rb

[![Gem Version](https://img.shields.io/gem/v/microsandbox-rb)](https://rubygems.org/gems/microsandbox-rb)
[![CI](https://github.com/ya-luotao/microsandbox-rb/actions/workflows/ci.yml/badge.svg)](https://github.com/ya-luotao/microsandbox-rb/actions/workflows/ci.yml)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D)](https://www.ruby-lang.org/)
[![Docs](https://img.shields.io/badge/docs-rubydoc.info-blue)](https://rubydoc.info/gems/microsandbox-rb)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)

Lightweight microVM sandboxes for Ruby. Run AI agents and untrusted code with hardware-level isolation from an idiomatic, **synchronous** Ruby API. The gem embeds the [microsandbox](https://github.com/superradcompany/microsandbox) runtime through a Rust (magnus) native extension: it boots real microVMs, not containers, in under 100 ms, runs standard OCI images, and needs no daemon or server.

> **Unofficial and community-maintained.** This gem is an independent project, not built, endorsed, or supported by [Super Rad Company](https://github.com/superradcompany) or the microsandbox team. All the hard parts (the microVM engine, the guest `agentd`, the networking stack) are theirs; this gem is a Ruby skin over them, tracked release by release. Please open issues [here](https://github.com/ya-luotao/microsandbox-rb/issues), not upstream. Upstream links: [website](https://microsandbox.dev) · [docs](https://docs.microsandbox.dev) · [official SDKs](https://github.com/superradcompany/microsandbox/tree/main/sdk) · [Agent Skills](https://github.com/superradcompany/skills) · [MCP server](https://github.com/superradcompany/microsandbox-mcp) · [Discord](https://discord.gg/T95Y3XnEAK).

## Highlights

- **Real VMs, not containers.** Every sandbox has its own Linux kernel under KVM (Linux) or the Hypervisor framework (Apple Silicon). Sub-100 ms boot; the runtime lives in your process.
- **Synchronous, idiomatic Ruby.** Keyword arguments, block-scoped lifecycle, a flat typed error hierarchy with stable `#code`s, and hand-maintained RBS signatures. The GVL is released during native calls, so other threads keep running.
- **The whole core surface.** Collected *and* streaming exec, logs, metrics, and filesystem handles; live `modify` with dry-run plans; snapshots; named volumes with host-side access; image cache management; interactive `attach`; in-process SSH/SFTP; a raw `agentd` client.
- **Network policy as data.** Composable profiles plus per-rule CIDR/domain allow-deny policies, TLS interception, outbound SOCKS4/SOCKS5 proxies, fail-closed strict hostname mode, and secrets injection with host allow-lists.
- **Convergent lifecycle.** `connect_or_create`, `restart`, `destroy`, and `wait_for_status` take a name to the state you want and refuse to touch a sandbox someone recreated under the same name.
- **Hermetic runtime.** The optional `microsandbox-rb-binaries` companion gem vendors a checksum-verified `msb` + `libkrunfw` in lockstep with the SDK, so production never downloads on first use. Without it, the runtime is provisioned into `~/.microsandbox` on demand.
- **Local or cloud.** The same API runs against the local libkrun backend or the microsandbox cloud, selected per process or per block.

## Installation

The gem is published as **`microsandbox-rb`** but is required as `microsandbox`
(the `microsandbox` name was already taken on RubyGems):

```ruby
# Gemfile
gem "microsandbox-rb", require: "microsandbox"
gem "microsandbox-rb-binaries"   # optional: vendored msb runtime + libkrunfw firmware
```

Then `bundle install`, or `gem install microsandbox-rb`. Installing the source
gem compiles the Rust extension, so the first install takes a few minutes.

**Prerequisites**

- Ruby 3.1 or newer.
- Linux with KVM enabled, or macOS on Apple Silicon. Cloud-only users
  (`MSB_BACKEND=cloud`) need neither.
- A stable Rust toolchain (1.91 or newer) on `PATH` to compile the source gem.
  Precompiled extension gems require no Rust but are not yet auto-published; see
  [docs/releasing.md](docs/releasing.md).
- The `msb` runtime and `libkrunfw` firmware, from the companion gem above or
  downloaded on first use. Provision ahead of time (a Docker layer, an
  air-gapped host) with:

```ruby
Microsandbox.install unless Microsandbox.installed?
```

The companion gem ships one platform gem each for `arm64-darwin`,
`x86_64-linux-gnu`, and `aarch64-linux-gnu`, must match the SDK version, and is
found automatically at `require "microsandbox"`. See
[docs/runtime.md](docs/runtime.md) for the resolution order, `MSB_PATH`, and
disabling the first-use download.

## Quick start

```ruby
require "microsandbox"

Microsandbox::Sandbox.create("hello", image: "public.ecr.aws/docker/library/python:3-slim") do |sb|
  output = sb.exec("python", ["-c", "print('Hello, World!')"])
  puts output.stdout      # => "Hello, World!\n"
  puts output.success?    # => true
end
# the sandbox is stopped automatically when the block returns
```

The examples pull from AWS's public Docker Library mirror because anonymous
Docker Hub pulls are rate-limited; `image: "python"` works too when you aren't.
See [docs/images.md](docs/images.md) for authenticated and private registries.

### Lifecycle

```ruby
# Create it, or connect to (and start) the one that already exists.
sb = Microsandbox::Sandbox.connect_or_create("box", image: "public.ecr.aws/docker/library/alpine:latest")
sb.status                                  # => :running
sb = sb.restart                            # stop + start
sb.destroy                                 # stop + remove

# Handles for existing sandboxes (cursor-paginated list, fine-grained control)
Microsandbox::Sandbox.list.map(&:name)
h = Microsandbox::Sandbox.get("box")       # => Microsandbox::SandboxHandle
h.request_stop
h.wait_until_stopped                       # => Microsandbox::SandboxStopResult
```

See [docs/lifecycle.md](docs/lifecycle.md) for the live `Sandbox` /
`SandboxHandle` split, `detach`, and the identity checks behind
`SandboxReplacedError`.

### Running commands

```ruby
Microsandbox::Sandbox.create("work", image: "public.ecr.aws/docker/library/python:3-slim") do |sb|
  out = sb.exec("ls", ["-la", "/etc"], cwd: "/", timeout: 30)
  out.exit_code                              # non-zero exit is data, not an exception
  sb.shell("cat /etc/os-release | grep VERSION").stdout

  # Stream events as they arrive; ExecHandle is a single-pass Enumerable
  sb.exec_stream("python", ["-u", "-c", "for i in range(3): print(i)"]).each do |event|
    print event.text if event.stdout?
  end

  sb.fs.write("/tmp/data.txt", "hello")
  sb.fs.read_text("/tmp/data.txt")           # => "hello"
  sb.fs.copy_to_host("/tmp/data.txt", "./data.txt")
end
```

See [docs/execution.md](docs/execution.md) for stdin pipes, signals, the
image's default command, SSH, and the threading and timeout caveats, and
[docs/filesystem.md](docs/filesystem.md) for the guest filesystem API.

### Networking and secrets

```ruby
Microsandbox::Sandbox.create("agent", image: "public.ecr.aws/docker/library/python:3-slim",
  network: Microsandbox::NetworkPolicy.custom(default_egress: :deny,
    rules: [{ action: :allow, direction: :egress, protocol: :tcp, port: 443,
              destination: Microsandbox::Destination.domain("api.example.com") }]),
  strict: true,
  proxy: Microsandbox::OutboundProxy.socks5("127.0.0.1:1080"),
  secrets: { "API_KEY" => { env: "HOST_API_KEY", allowed_hosts: ["api.example.com"] } }
) do |sb|
  # ...
end
```

See [docs/configuration.md](docs/configuration.md) for every create option,
including resources, ports, volumes, and root-disk layout.

### Observability and live modification

```ruby
sb.metrics.cpu_percent                     # metrics slot goes live a beat after boot
sb.logs(tail: 100).each { |e| puts e.text }
sb.ping.latency_ms
sb.modify(cpus: 2, memory: 1024, dry_run: true).changes   # preview, then apply
```

See [docs/observability.md](docs/observability.md).

## Documentation

| Topic | Guide |
|-------|-------|
| Create, stop, handles, convergent lifecycle, identity checks | [docs/lifecycle.md](docs/lifecycle.md) |
| Create options: resources, network policy, strict mode, proxies, secrets, volumes | [docs/configuration.md](docs/configuration.md) |
| `exec`/`shell`, default workload, streaming, single-pass streams, threads and timeouts, SSH, raw agent client | [docs/execution.md](docs/execution.md) |
| Guest filesystem, streaming reads/writes, host copies | [docs/filesystem.md](docs/filesystem.md) |
| Metrics, logs, `ping`/`touch`, live `modify` plans | [docs/observability.md](docs/observability.md) |
| Image cache, private registries, snapshots | [docs/images.md](docs/images.md) |
| Runtime binaries gem, `msb` resolution order, backends, environment variables | [docs/runtime.md](docs/runtime.md) |
| Error classes and stable codes | [docs/errors.md](docs/errors.md) |
| Complete supported surface and what is not yet exposed | [docs/surface.md](docs/surface.md) |
| Release process, precompiled and binaries gems | [docs/releasing.md](docs/releasing.md) |
| Architecture: native extension, sync bridge, GVL, error mapping | [DESIGN.md](DESIGN.md) |
| Companion runtime gem internals | [binaries/README.md](https://github.com/ya-luotao/microsandbox-rb/blob/main/binaries/README.md) |

API reference: [rubydoc.info/gems/microsandbox-rb](https://rubydoc.info/gems/microsandbox-rb).
Type signatures: [`sig/microsandbox.rbs`](sig/microsandbox.rbs).

## Comparison with the official Ruby gem

Since upstream `v0.6.9` the microsandbox repository ships an official
`microsandbox` gem built from
[`sdk/ruby`](https://github.com/superradcompany/microsandbox/tree/main/sdk/ruby),
a compact veneer over the same Rust SDK. Both gems define the `Microsandbox`
module, so use one or the other in a process, not both. Differences below are
taken from the official gem's own README as of upstream `v0.6.18`.

| Capability | `microsandbox-rb` (this gem) | official `microsandbox` gem |
|---|:---:|:---:|
| Lifecycle, convergent `connect_or_create`, local/cloud backends | ✅ | ✅ |
| Collected `exec`/`shell`, logs, metrics, guest filesystem | ✅ | ✅ |
| Image, volume, and snapshot management | ✅ | ✅ |
| Streaming exec, logs, metrics, filesystem handles | ✅ | not exposed |
| Interactive SSH/SFTP client and server | ✅ | `ssh_exec` only |
| Live modification plans (`modify`, dry-run) | ✅ | not exposed |
| Outbound SOCKS proxy (`proxy:`) | ✅ | ✅ |
| Full network policy and mount builders, strict hostname mode | ✅ | not exposed |
| Rootfs patches, structured root disk, raw `agentd` client | ✅ | — |
| RBS type signatures | ✅ | — |
| Runtime binaries | companion gem or first-use download | first-use download |
| Version numbering | own semver; runtime tag via `Microsandbox.runtime_version` | mirrors the upstream tag |

## Versioning

The gem follows its **own** [semantic version](https://semver.org/), independent
of the upstream runtime it embeds: early releases (`0.5.7`–`0.5.9`) happened to
share the upstream tag, but the numbers have diverged since and the gem version
is **not** an indicator of the embedded runtime. Ask the build instead:

```ruby
Microsandbox::VERSION          # => "0.17.0"  (the gem's own version)
Microsandbox.runtime_version   # => "v0.6.18" (the embedded upstream runtime tag)
```

While the gem is `0.x`, a breaking API change bumps the minor and a fix bumps
the patch. Adopting a new upstream runtime bumps the gem version, the pinned
git tag, `Microsandbox::RUNTIME_VERSION`, and the table below together. The
companion `microsandbox-rb-binaries` gem is versioned in lockstep (same number,
released together) and pins the same runtime; the test suite asserts both
constants against this gem's. Every release records its runtime in
[CHANGELOG.md](CHANGELOG.md).

| Gem version | Upstream runtime | Notes |
|-------------|------------------|-------|
| `0.5.7`  | `v0.5.7` | initial release |
| `0.5.8`  | `v0.5.7` | gem-only revision |
| `0.5.9`  | `v0.5.7` | gem-only revision |
| `0.5.10` | `v0.5.8` | adopts upstream `v0.5.8`; **breaking** lifecycle split |
| `0.5.11` | `v0.5.8` | gem-only revision |
| `0.5.12` | `v0.5.8` | gem-only revision |
| `0.6.0`  | `v0.5.8` | gem version decoupled from the upstream tag; adds `runtime_version` |
| `0.7.0`  | `v0.5.8` | SDK parity release (large binding-gap closure) |
| `0.8.0`  | `v0.5.10` | adopts upstream `v0.5.10` (idle-only heartbeat, config-fd hardening, **4 GiB default bind-mount quota**); supersedes the reverted `v0.5.9` attempt |
| `0.8.1`  | `v0.5.10` | gem-only: re-provision a stale local runtime; per-bind-mount `quota_mib:` override |
| `0.8.2`  | `v0.5.10` | gem-only: redact secrets from errors, typed snapshot errors, panic-free durations, fat-gem loader + `extconf` preflight fixes, threading/streaming docs |
| `0.9.0`  | `v0.6.1` | adopts upstream `v0.6.0`+`v0.6.1` (zombie-runtime wait fix, secret substitution through CONNECT proxies, stale-sandbox cleanup); upstream public API is additive — no Ruby surface change |
| `0.9.1`  | `v0.6.2` | adopts upstream `v0.6.2` (faster image loads/pulls via early cache gate + zlib-rs); upstream API unchanged — no Ruby surface change |
| `0.9.2`  | `v0.6.3` | adopts upstream `v0.6.3` (v4-only sandboxes stop advertising AAAA DNS answers — fixes guest gRPC/c-ares preferring unreachable IPv6; scoped upstream TLS verification); glue moves to `*_local` SDK variants — no Ruby surface change |
| `0.9.3`  | `v0.6.6` | adopts upstream `v0.6.4`+`v0.6.6` (`v0.6.5` was yanked upstream): snapshot restore by pinned digest — fixes fatal restore-after-tag-republish bug, fragmented-UDP/PMTU relay fixes, exec kills the whole process group, ephemeral stop-wait tolerance, readdir RSS-leak fix; upstream API growth is additive-only — no Ruby surface change |
| `0.10.0` | `v0.6.6` | `v0.6.6` API parity: live `modify`/resize, `ping`/`touch`, create `max_cpus`/`max_memory` |
| `0.11.0` | `v0.6.7` | adopts upstream `v0.6.7` (**breaking**): network profiles replace `public_only`/`non_local`, structured `root_disk:` replaces `oci_upper_size:` (deprecated alias kept), snapshot descriptor contract (`create` re-keyed by name, `save`/`load` rename, `snapshot_to` removed, on-disk auto-migration), `Image.load`/`Image.save`, `follow_root_symlinks:`; runtime carries the GHSA-4vq3-cjpp-v7fg `msb copy` fix |
| `0.12.0` | `v0.6.8` | adopts upstream `v0.6.8` (**breaking**): `Sandbox.list`/`.list_with` return a cursor-paginated `SandboxPage` (`limit:`/`cursor:` keywords), `UnsupportedError` re-keyed by structured operations with `#operation`/`#hint`; runtime adds a shared log registry for followed streams and cloud exec/ssh reconnects |
| `0.13.0` | `v0.6.9` | adopts upstream `v0.6.9` (**breaking**): a bare `MSB_API_KEY` no longer selects the cloud backend (explicit `MSB_BACKEND=cloud` or a cloud profile required; invalid cloud config fails closed with `InvalidConfigError`); snapshot payload integrity becomes opt-in (`record_integrity:`, `verify` can report `:not_recorded`). Parity: default-workload execution (`exec_default`/`exec_default_stream`/`attach_default`, `cmd:`), flat root disks (`RootDisk.flat`), `modify(root_disk_size:)`, `rate_limiter:`, `vsock:`, `default_backend_info`, `Volume.get_default` |
| `0.14.0` | `v0.6.9` | two-gem split: SDK-only gem (no build-time runtime download) + companion `microsandbox-rb-binaries` platform gems |
| `0.15.0` | `v0.6.14` | adopts upstream `v0.6.10`–`v0.6.14` step by step: bind-mount correctness, guest bootstrap off the kernel command line, DNS pins for deferred domain allows, Linux glibc 2.28 baseline for the prebuilt runtime, legacy ext4 upper-disk resize, `msb_krun` 0.1.32. Parity: `ssh.open_client`/`prepare_server` accept `inactivity_timeout:` (seconds; `0` disables, `nil` inherits the 600s global default) |
| `0.16.0` | `v0.6.16` | adopts upstream `v0.6.15`+`v0.6.16` step by step: mount fallback ownership, readonly-mount write-probe fix, log retrieval rerouted through the SDK backends, config overlaid by field presence, network-slot recycling. Parity: per-mount `uid:`/`gid:`, and the convergent lifecycle — `Sandbox.connect_or_create`, `#id`, `#wait_for_status`, `#restart`, `#destroy`, `SandboxHandle#connect_or_start`, `SandboxReplacedError` |
| `0.17.0` | `v0.6.18` | adopts upstream `v0.6.17`+`v0.6.18` step by step: outbound SOCKS4/SOCKS5 proxies (SOCKS5 UDP + credentials), migration-order fix for databases last opened by a `v0.6.15` `msb`, security hardening — plain-HTTP `Host`/`:authority` now checked against domain-rule policies even in non-strict mode, plus fail-closed strict hostname mode. Parity: `proxy:` (`Microsandbox::OutboundProxy` / `SecretSource`), `strict:` |

## Development

```bash
bin/setup                                  # bundle install + compile the native extension
bundle exec rake compile                   # rebuild the extension (debug); compile:release for optimized
bundle exec rake spec                      # unit specs (no runtime needed)
MICROSANDBOX_INTEGRATION=1 bundle exec rspec spec/integration   # boot real microVMs (KVM / Apple Silicon)
bundle exec standardrb                     # Ruby lint
cargo fmt --check --manifest-path ext/microsandbox/Cargo.toml
cargo clippy --manifest-path ext/microsandbox/Cargo.toml -- -D warnings
```

CI compiles and runs the unit suite on Ruby 3.1 through 3.4 on Linux and macOS,
lints Rust and Ruby, packages and installs the built gems, builds every
`microsandbox-rb-binaries` platform gem, and boots real microVMs in a KVM
integration job against both the provisioned and the bundled runtime.

The native extension pins the upstream core crate by git tag, so it builds
without an adjacent checkout. To develop against a sibling `microsandbox/`
checkout instead:

```bash
cp .cargo/config.toml.example .cargo/config.toml   # gitignored path override
bundle exec rake compile
```

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/ya-luotao/microsandbox-rb/issues). Please include a
failing spec with bug reports where possible and keep pull requests focused on
one change; PRs target `main`. When the public API changes, update
`sig/microsandbox.rbs` and `CHANGELOG.md` in the same change, and run the local
gate (`cargo fmt`/`clippy`, `standardrb`, unit specs) before pushing.

## License

Released under the [Apache License 2.0](LICENSE).
