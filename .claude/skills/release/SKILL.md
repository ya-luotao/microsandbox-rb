---
name: release
description: Cut a release of the microsandbox-rb gem — walk the version lock-step SOP and tag vX.Y.Z to trigger the OIDC publish. Usage: /release <version> (e.g. /release 0.5.10). User-triggered only.
disable-model-invocation: true
---

Cut a release for version `$ARGUMENTS` (e.g. `0.5.10`). If no version was given, ask for it before
doing anything. This has side effects (commits, tags, triggers publishing) — confirm the target
version with the user before pushing the tag.

## Steps

1. **Confirm a clean tree on `main`** (or the intended release branch) and that CI is green.

2. **Bump the gem version in BOTH files (they must match — `version_spec.rb` enforces it):**
   - `lib/microsandbox/version.rb` → `VERSION = "$ARGUMENTS"`
   - `ext/microsandbox/Cargo.toml` `[package]` → `version = "$ARGUMENTS"`

   The gem version is on its OWN semver track, independent of the upstream runtime tag — do NOT
   pick `$ARGUMENTS` to mirror the runtime version. While 0.x, a breaking API change bumps the
   minor; a fix/addition bumps the patch. (See the Versioning section of `README.md`.)

3. **Upstream runtime tag — only if this release adopts a new upstream runtime.** This is a
   SEPARATE axis from the gem version. If adopting a new runtime, update the `tag = "vX.Y.Z"` for
   BOTH `microsandbox` and `microsandbox-network` git deps in `ext/microsandbox/Cargo.toml` to the
   same tag, then ALSO update `Microsandbox::RUNTIME_VERSION` in `lib/microsandbox/version.rb` to
   match (`version_spec.rb` asserts the constant equals the Cargo tag) and add a row to the
   Versioning table in `README.md`. Then `bundle exec rake compile` to refresh `Cargo.lock`.
   Otherwise leave all of these untouched.

4. **Update `CHANGELOG.md`** (Keep-a-Changelog) — move Unreleased items under a new
   `## [$ARGUMENTS] - <date>` heading.

5. **Verify locally** before tagging: run the `verify-local` skill (cargo fmt --check, clippy
   -D warnings, rake spec). Do not proceed if anything fails.

6. **Commit** the version + changelog bump with a conventional message, e.g.
   `chore(release): v$ARGUMENTS`.

7. **Tag and push** — this is what triggers the publish, so confirm with the user first:
   ```sh
   git tag v$ARGUMENTS && git push origin main v$ARGUMENTS
   ```

8. **CI does the rest on the `v*` tag** (`.github/workflows/release.yml`):
   - `source gem` + `publish to RubyGems` build the source gem and push it via Trusted Publishing
     (OIDC) — no API key.
   - `GitHub Release` then creates the GitHub Release from the matching `CHANGELOG.md` section
     (the `## [X.Y.Z]` heading the awk slice keys on, so keep step 4's format) and marks it latest.
     It is idempotent on re-runs. If a Release ever needs doing by hand — e.g. backfilling an old
     tag — slice the section and `gh release create vX.Y.Z --title vX.Y.Z --notes-file notes.md
     --latest --verify-tag` (use `--latest=false` for non-newest backfills, then
     `gh release edit <newest> --latest`).

   Precompiled platform gems are NOT published by this tag flow — they require manual
   `workflow_dispatch` and per-platform validation. Mention this if the user expected fat gems.

Report what you changed and the tag you pushed, and link the user to the Actions run if `gh` is
available (`gh run list --workflow=release.yml`). Confirm the GitHub Release was created
(`gh release view vX.Y.Z`).
