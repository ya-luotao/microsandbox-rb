# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Ruby gem wrapping the upstream `microsandbox` Rust crate (secure microVM sandboxing) through a
magnus + rb-sys native extension. Two layers:

- `lib/microsandbox/` — idiomatic, **synchronous** Ruby API (the public surface).
- `ext/microsandbox/src/` — magnus bindings over the async (tokio) core crate. The async core is
  bridged to sync Ruby via a shared blocking tokio runtime; the GVL is released
  (`rb_thread_call_without_gvl`) during blocking calls. Built as `microsandbox_rb.{bundle,so}`.

Plus a companion gem in its own subtree:

- `binaries/` — source + build pipeline for `microsandbox-rb-binaries`, the optional platform gem
  shipping the prebuilt `msb` runtime and `libkrunfw` firmware (`rake -C binaries vendor[<platform>]
  build[<platform>]`). It is NOT part of this gem's bundle and has no dependency edge to it in
  either direction; the SDK discovers it at `require "microsandbox"` time. See `binaries/README.md`.

Deeper architecture is in `DESIGN.md`; usage in `README.md`.

## Build / test / lint

- Compile the native ext: `bundle exec rake compile` (release: `rake compile:release`). Requires
  **stable Rust ≥ 1.91** on PATH — the core crate is edition 2024 / pulls smoltcp; an older rustc
  fails the `extconf.rb` preflight. `rust-toolchain.toml` pins `stable`.
- Unit specs (no runtime needed): `bundle exec rake spec` (the default task; auto-compiles first).
- Integration specs (boot real microVMs, **Linux+KVM or macOS Apple Silicon**):
  `MICROSANDBOX_INTEGRATION=1 bundle exec rspec spec/integration`. They auto-skip without that env
  var or a missing runtime — never assume a green unit run exercised them.
- Companion binaries gem: `rake -C binaries vendor[<platform>]` (download + sha256-verify the
  upstream runtime bundle into `binaries/vendor`), `rake -C binaries build[<platform>]` (re-verify
  against the manifest, package into `binaries/pkg`), `rake -C binaries verify` (host-only: run the
  vendored `msb --version`), `rake -C binaries vendor:all` (every platform — vendoring only
  downloads, so it needs no matching host). Platforms: `arm64-darwin`, `x86_64-linux-gnu`,
  `aarch64-linux-gnu`. **`binaries/vendor` and `binaries/pkg` are gitignored — never commit
  binaries**; CI rebuilds them from the upstream release.
- Lint:
  - Rust: `cargo fmt --check --manifest-path ext/microsandbox/Cargo.toml` and
    `cargo clippy --manifest-path ext/microsandbox/Cargo.toml -- -D warnings`. Always pass
    `--manifest-path ext/microsandbox/Cargo.toml` — the workspace root has no buildable crate.
  - Ruby (`lib/`, `spec/`): `bundle exec standardrb` (zero-config StandardRB; autocorrect with
    `bundle exec standardrb --fix`).

  CI gates on all three — run them before claiming a change is done. The `verify-local` skill runs
  the Rust + spec gate in one shot.

## Version lock-step (three independent axes)

1. **Gem version** — `Microsandbox::VERSION` in `lib/microsandbox/version.rb` MUST equal `version`
   in `ext/microsandbox/Cargo.toml` `[package]`. `spec/unit/version_spec.rb` asserts equality via
   `Native.version`. Bump both together, or specs fail. The gem follows its OWN semver and is NOT
   numbered to mirror the upstream tag — the `0.5.x` lineage stopped mapping 1:1 once gem-only
   revisions (and a bundled breaking change) diverged the two numbers. While 0.x, a breaking API
   change bumps the minor and a fix bumps the patch. See the Versioning section of `README.md` for
   the gem→runtime map.
2. **Upstream runtime tag** — the `microsandbox` and `microsandbox-network` git deps in
   `ext/microsandbox/Cargo.toml` are pinned to a `tag` (see `Microsandbox::RUNTIME_VERSION` for
   the current pin — the hardcoded value here kept going stale). This tracks the
   upstream runtime, NOT the gem version. Bump it only when adopting a new upstream release, keep
   both deps on the same tag, AND update `Microsandbox::RUNTIME_VERSION` in
   `lib/microsandbox/version.rb` to match — `spec/unit/version_spec.rb` asserts the constant equals
   the Cargo tag, so it can't silently go stale.
3. **Companion binaries gem** — `Microsandbox::Binaries::VERSION`
   (`binaries/lib/microsandbox/binaries.rb`) MUST equal `Microsandbox::VERSION`, and
   `Microsandbox::Binaries::RUNTIME_VERSION` MUST equal `Microsandbox::RUNTIME_VERSION`.
   `spec/unit/version_spec.rb` asserts both. So a release bumps the gem version in three places
   (version.rb, Cargo.toml, binaries.rb), and a runtime adoption bumps the tag in three places
   (both Cargo git deps, `RUNTIME_VERSION`, `Binaries::RUNTIME_VERSION`), commits the new
   release's `checksums.sha256` as `binaries/checksums/<tag>.sha256` (vendoring fails closed
   without it, and refuses if the live release file disagrees with the committed one) — then
   re-vendor the binaries for the new runtime. A mismatched companion gem isn't fatal at runtime: the SDK warns
   and falls back to `~/.microsandbox`.

## Conventions

- When the public Ruby API changes, update `sig/microsandbox.rbs` (hand-maintained RBS) and
  `CHANGELOG.md` (Keep-a-Changelog) in the same change.
- Commits: conventional style, e.g. `fix(exec): ...`, `docs(readme): ...`. Branches:
  `feature/<desc>`, `fix/<desc>`. PRs target `main`.

## Env vars & gotchas

- `MICROSANDBOX_INTEGRATION=1` — opt in to integration specs. `MICROSANDBOX_TEST_IMAGE` — override
  the test image (default `public.ecr.aws/docker/library/alpine:latest`, an ECR mirror to dodge
  docker.io rate limits). `MSB_PATH` — override the resolved `msb` runtime binary.
  `MICROSANDBOX_NO_AUTO_INSTALL` — opt out of first-use runtime download.
- With the `microsandbox-rb-binaries` gem installed, `Microsandbox.runtime_path=` is a **no-op**:
  `require "microsandbox"` already claimed the core's set-once SDK slot with the gem's vendored
  `msb`. Use `MSB_PATH` (which outranks the slot) to point at a different runtime.
- `Gemfile` uses `gemspec glob: "{,*}.gemspec"` on purpose: Bundler's default glob would also
  evaluate `binaries/microsandbox-rb-binaries.gemspec` in every `bundle exec` process, defining
  `Microsandbox::Binaries` before the SDK can decide whether the gem is actually installed. Don't
  drop the glob.
- Local dev against a sibling `../microsandbox` checkout: `cp .cargo/config.toml.example
  .cargo/config.toml` (gitignored). **Never commit `.cargo/config.toml`** — it breaks CI/container
  builds, which rely on the pinned git dep.

## Release

Push a `vX.Y.Z` tag → `.github/workflows/release.yml` builds the source gem AND the three
`microsandbox-rb-binaries` platform gems (`binaries-gems` job: `rake -C binaries vendor:all`,
version checked against the tag) and publishes all four to RubyGems via Trusted Publishing (OIDC —
no API key; the binaries gem has its own trusted-publisher entry for its gem name, same repo +
workflow). The SDK gem is pushed first and on its own, so a companion-gem push failure never
blocks the SDK release — it fails the job afterwards, and a re-run finishes the set
(idempotent). Precompiled *extension* platform gems are built only via manual `workflow_dispatch`
and require per-platform validation before promotion; they do not auto-publish on tags.
