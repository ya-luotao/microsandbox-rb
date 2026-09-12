# Releasing

Releases are automated by `.github/workflows/release.yml` via RubyGems
**Trusted Publishing** (OIDC) — there is no API key to store as a secret. The
trusted publisher is already configured for this gem, so no per-release secret
or credential setup is needed.

## Each release

1. Bump the gem's **own** version — `Microsandbox::VERSION` and the matching
   `[package] version` in `ext/microsandbox/Cargo.toml` (they must stay equal) —
   on its independent semver track (see the
   [Versioning](../README.md#versioning) section of the README); **don't** pick
   the number to mirror the upstream tag. If the release also adopts a new
   upstream runtime, bump the `tag = "vX.Y.Z"` on **all three** upstream git
   deps (`microsandbox`, `microsandbox-network`, `microsandbox-runtime`), update
   `Microsandbox::RUNTIME_VERSION` to match, commit the release's
   `checksums.sha256` as `binaries/checksums/<tag>.sha256`, and add a row to the
   Versioning table. Also bump `Microsandbox::Binaries::VERSION` (and, on a
   runtime adoption, `::RUNTIME_VERSION`) in
   `binaries/lib/microsandbox/binaries.rb` — the companion gem ships in
   lockstep and the specs assert both. Update `CHANGELOG.md`.
2. Push a `vX.Y.Z` tag. CI builds the **source gem** and pushes it to RubyGems
   via `rubygems/configure-rubygems-credentials` (OIDC, `id-token: write`) — no
   `RUBYGEMS_API_KEY` secret required — then creates the GitHub Release.

## Precompiled per-platform gems

Precompiled *extension* gems are built best-effort by the `cross-gems` job,
gated to manual `workflow_dispatch` so you can iterate
(`gh workflow run release.yml`) without failing tag releases. They are not
auto-published on tags yet: a gem that *compiles but can't boot a microVM*
would be served to users ahead of the source gem, and CI can't boot a VM to
prove otherwise — so promotion is manual after validating the artifact on each
platform. A precompiled gem ships the compiled extension (with the guest
`agentd` baked in by *target* arch); the host-side `msb` + `libkrunfw` runtime
is **not** in it — that comes from the companion `microsandbox-rb-binaries`
gem, or, when that isn't installed, is fetched into `~/.microsandbox` on first
use by `Microsandbox.ensure_runtime!` (libkrunfw is `dlopen`'d by `msb` at
runtime, never linked into the gem). The real cross-compile work is linking the
*target* native libraries — `libcap-ng` on Linux (handled via Debian multiarch
in the workflow) and the Hypervisor + Security frameworks on macOS (via
osxcross; the one platform left to confirm). Until promoted, users install the
source gem (which compiles via `rb_sys`).

## Runtime binaries gems

`microsandbox-rb-binaries` (source in `binaries/`) is a *separate* artifact from
the precompiled extension gems above: it carries no Ruby extension, only the
upstream `msb` + `libkrunfw` for one platform, verified against the release's
published `checksums.sha256` when vendored. CI's `binaries` job vendors and
builds all three (`arm64-darwin`, `x86_64-linux-gnu`, `aarch64-linux-gnu`) on
every run and smoke-tests the host one; `release.yml`'s `binaries-gems` job
does the same on a tag and a separate `publish-binaries` job pushes them after
the SDK gem is live (a companion failure is its own red job and never blocks
the SDK release). They use their own RubyGems trusted-publisher entry (same
repo + workflow, gem name `microsandbox-rb-binaries`). To build them by hand:

```bash
rake -C binaries vendor[arm64-darwin]   # download + sha256-verify into binaries/vendor
rake -C binaries build[arm64-darwin]    # package into binaries/pkg/*.gem
rake -C binaries verify                 # host-only: run the vendored `msb --version`
```

`binaries/vendor` and `binaries/pkg` are gitignored — binaries are never
committed; CI rebuilds them from the upstream release.
