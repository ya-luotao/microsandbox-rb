# microsandbox-rb-binaries

Prebuilt `msb` microVM runtime + `libkrunfw` firmware for the
[`microsandbox-rb`](https://github.com/ya-luotao/microsandbox-rb) gem, shipped as
one gem per platform so your bundle carries the runtime instead of downloading
it into `~/.microsandbox` on first use.

```ruby
# Gemfile — install both gems at the same version
gem "microsandbox-rb", require: "microsandbox"
gem "microsandbox-rb-binaries"
```

That's it: `require "microsandbox"` finds this gem, checks that it is the
lockstep version built for the same upstream runtime release
(`Microsandbox::Binaries::VERSION` must equal `Microsandbox::VERSION` and
`::RUNTIME_VERSION` must equal `Microsandbox::RUNTIME_VERSION`), and hands its
`msb` to the core resolver. `Microsandbox.runtime_path` then points into this gem's `vendor/`.
`MSB_PATH` (environment) still overrides it. A version mismatch is reported
with a warning and the SDK falls back to its first-use download.

Cloud-only users (`MSB_BACKEND=cloud`) never need this gem — that is why it is
a separate, optional install rather than a dependency of `microsandbox-rb`.

## Platforms

| RubyGems platform   | Upstream bundle                   |
|---------------------|-----------------------------------|
| `arm64-darwin`      | `microsandbox-darwin-aarch64`     |
| `x86_64-linux-gnu`  | `microsandbox-linux-x86_64`       |
| `aarch64-linux-gnu` | `microsandbox-linux-aarch64`      |

The Linux binaries are glibc-linked (RubyGems ≥ 3.3.11 keeps them off musl
hosts). Other platforms: don't install this gem — `microsandbox-rb` provisions
the runtime into `~/.microsandbox` on first use instead.

## What's inside

```
vendor/
  manifest.json        platform, runtime version, bundle + per-file sha256
  bin/msb              the microVM runtime (spawned as a child process)
  lib/libkrunfw.*      the firmware msb dlopen()s, found by ../lib adjacency
```

`Microsandbox::Binaries.msb_path` / `.libkrunfw_path` / `.manifest` expose the
vendored files. The layout mirrors the upstream release bundle and
`~/.microsandbox`, so the core resolver needs only the `msb` path.

## Building

Every file comes from the upstream GitHub release named by `RUNTIME_VERSION`
and is verified against that release's `checksums.sha256` before it is staged —
the copy **committed in `checksums/<tag>.sha256`** (reviewed into this repo when
a runtime is adopted), which the live file must still agree with, since a GitHub
release asset and its checksum file can be re-uploaded together. The gem build
re-verifies the staged tree against the manifest (regular files only, no
symlinks). Nothing unverified is ever packaged.

```sh
cd binaries
rake vendor[arm64-darwin]   # download + verify into vendor/
rake build[arm64-darwin]    # package pkg/microsandbox-rb-binaries-<ver>-arm64-darwin.gem
rake verify                 # host-only: run vendor/bin/msb --version
rake vendor:all             # all three platforms (no matching host needed: just downloads)
```

Versioning: `Microsandbox::Binaries::VERSION` tracks `microsandbox-rb` in
lockstep (released together, same number); `RUNTIME_VERSION` tracks the
upstream runtime the binaries come from. Both are asserted by the SDK's
`spec/unit/version_spec.rb`. Adopting a new runtime means bumping
`RUNTIME_VERSION`, committing that release's `checksums.sha256` as
`checksums/<tag>.sha256`, and re-vendoring.

## License

Apache-2.0 — the same license as the upstream
[microsandbox](https://github.com/superradcompany/microsandbox) project whose
release binaries this gem redistributes unmodified.
