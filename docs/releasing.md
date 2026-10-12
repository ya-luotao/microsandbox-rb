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
2. Push a `vX.Y.Z` tag. Once the [release preflight](#release-preflight)
   passes, CI pushes the **source gem** to RubyGems via
   `rubygems/configure-rubygems-credentials` (OIDC, `id-token: write`) — no
   `RUBYGEMS_API_KEY` secret required — then creates the GitHub Release.

## Release preflight

`release.yml`'s `preflight` job runs `.github/scripts/release_preflight.sh
<tag>` and the `publish` job needs it, so nothing reaches RubyGems unless:

- the tag is `vX.Y.Z` and the three version constants **in the tagged commit**
  — `Microsandbox::VERSION`, `[package] version` in
  `ext/microsandbox/Cargo.toml`, `Microsandbox::Binaries::VERSION` — all equal
  `X.Y.Z`;
- the tagged commit is on `main`;
- the `CI` workflow's push run for that exact commit concluded `success`.

Pushing `main` and the tag together is fine: the preflight **waits** for that
CI run to appear and finish (polling every 30 s, up to 45 min —
`PREFLIGHT_CI_WAIT_SECONDS` / `PREFLIGHT_CI_POLL_SECONDS`), so a release
publishes only after CI, including the real-microVM integration lanes, is
green. A failed or timed-out preflight leaves the tag unpublished. How to
recover depends on whether the tag has to move:

- **The tagged commit is right** (CI flaked, or was still red): re-run the
  `CI` run for that commit until it is green, then re-run the failed `Release`
  run.
- **The tag must point at a different commit** (wrong version constants, not
  on `main`): delete the tag, fix the commit, and push the tag again — that
  starts a new `Release` run. Never re-run the old run after retagging: a
  re-run keeps the commit it was started for, so it checks the old commit
  again and fails the same way.

Dry-run it against an existing tag — nothing is published on a manual
dispatch — or run the script locally from a full clone:

```bash
gh workflow run release.yml --ref main -f preflight_ref=vX.Y.Z
GH_TOKEN=$(gh auth token) .github/scripts/release_preflight.sh vX.Y.Z
```

It is a workflow-level gate; branch protection and a protected environment for
the trusted publisher are separate repository settings.

CI's `lint` job also runs `cargo deny check advisories` against `Cargo.lock`;
the exceptions (advisories with no fixed release at the pinned runtime) are in
`deny.toml` at the repository root — re-check them on every runtime adoption.

## Precompiled per-platform gems

Precompiled *extension* gems are not built or published. Users install the
source gem, which compiles the extension via `rb_sys` at install time (so a
stable Rust toolchain is required on the installing host). The companion
`microsandbox-rb-binaries` gems below are unaffected: they carry the host
runtime, not the extension.

## Runtime binaries gems

`microsandbox-rb-binaries` (source in `binaries/`) is a *separate* artifact from
the SDK gem: it carries no Ruby extension, only the
upstream `msb` + `libkrunfw` for one platform, verified against the release's
published `checksums.sha256` when vendored. CI's `binaries` job vendors and
builds all three (`arm64-darwin`, `x86_64-linux-gnu`, `aarch64-linux-gnu`) on
every run and smoke-tests the host one; `release.yml`'s `binaries-gems` job
does the same on a tag and a separate `publish-binaries` job pushes them after
the SDK gem is live. The SDK `publish` job needs `binaries-gems`, so a
companion **build** failure blocks the SDK publish as well. A companion
**push** failure is its own red job once the SDK gem is live: the release is
then incomplete until `publish-binaries` is re-run. They use their own RubyGems
trusted-publisher entry (same repo + workflow, gem name
`microsandbox-rb-binaries`). To build them by hand:

```bash
rake -C binaries vendor[arm64-darwin]   # download + sha256-verify into binaries/vendor
rake -C binaries build[arm64-darwin]    # package into binaries/pkg/*.gem
rake -C binaries verify                 # host-only: run the vendored `msb --version`
```

`binaries/vendor` and `binaries/pkg` are gitignored — binaries are never
committed; CI rebuilds them from the upstream release.
