#!/usr/bin/env bash
#
# Release preflight: refuse to publish a tag that is not a real, green release.
#
#   release_preflight.sh <tag>
#
# Checks, in order (each failure exits 1 with a message naming what is wrong):
#   1. <tag> is a release tag (vX.Y.Z).
#   2. The tag resolves to a commit (annotated tags are dereferenced).
#   3. The three lock-step version constants IN THE TAGGED COMMIT all equal X.Y.Z:
#        Microsandbox::VERSION            lib/microsandbox/version.rb
#        [package] version                ext/microsandbox/Cargo.toml
#        Microsandbox::Binaries::VERSION  binaries/lib/microsandbox/binaries.rb
#   4. The tagged commit is on origin/main (needs full history: fetch-depth 0).
#   5. The `CI` workflow's push run for that exact commit concluded `success`.
#      The release SOP pushes main and the tag together, so that run may be in
#      progress or not created yet when this starts: wait for it, bounded.
#
# Environment:
#   GH_TOKEN                   token for `gh` (CI: github.token with actions:read;
#                              locally an existing `gh auth login` also works)
#   GH_REPO                    owner/repo; optional inside a checkout whose origin
#                              is the repository
#   PREFLIGHT_CI_WAIT_SECONDS  how long to wait for the CI run (default 2700)
#   PREFLIGHT_CI_POLL_SECONDS  delay between polls (default 30)
#
# Read-only: it fetches origin/main and queries the Actions API, nothing else.

set -euo pipefail

fail() {
  echo "preflight FAILED: $*" >&2
  exit 1
}

[ "$#" -eq 1 ] || { echo "usage: $(basename "$0") <tag>   (e.g. v1.2.3)" >&2; exit 2; }

tag="$1"
wait_seconds="${PREFLIGHT_CI_WAIT_SECONDS:-2700}"
poll_seconds="${PREFLIGHT_CI_POLL_SECONDS:-30}"

[[ "$wait_seconds" =~ ^[0-9]+$ ]] || fail "PREFLIGHT_CI_WAIT_SECONDS must be a whole number of seconds, got '$wait_seconds'"
[[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] || fail "PREFLIGHT_CI_POLL_SECONDS must be a positive whole number of seconds, got '$poll_seconds'"

# 1. A release tag, nothing else.
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "'$tag' is not a release tag (expected vX.Y.Z, e.g. v1.2.3)"
version="${tag#v}"

cd "$(git rev-parse --show-toplevel)"

# 2. Tag -> commit. `^{commit}` peels an annotated tag; refs/tags/ keeps a
#    same-named branch from answering.
sha="$(git rev-parse --verify --quiet "refs/tags/${tag}^{commit}")" ||
  fail "tag $tag does not exist in this checkout (fetch tags, or push the tag first)"
echo "tag $tag -> commit $sha"

# 3. Version constants, read from the tagged commit rather than the working
#    tree: on a tag push the two are the same, on a dry run (`--ref main`) they
#    need not be.
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
version_rb="lib/microsandbox/version.rb"
cargo_toml="ext/microsandbox/Cargo.toml"
binaries_rb="binaries/lib/microsandbox/binaries.rb"
git archive "$sha" -- "$version_rb" "$cargo_toml" "$binaries_rb" | tar -x -C "$tree" ||
  fail "could not read the version files from $sha"

sdk_version="$(ruby -I "$tree/lib" -r microsandbox/version -e 'print Microsandbox::VERSION')" ||
  fail "could not evaluate Microsandbox::VERSION from $version_rb at $tag"
cargo_version="$(awk '
  /^\[/ { in_package = ($0 == "[package]") }
  in_package && /^version[[:space:]]*=/ { gsub(/^[^"]*"|".*$/, ""); print; exit }
' "$tree/$cargo_toml")"
binaries_version="$(ruby -r "$tree/$binaries_rb" -e 'print Microsandbox::Binaries::VERSION')" ||
  fail "could not evaluate Microsandbox::Binaries::VERSION from $binaries_rb at $tag"

echo "version constants at $tag (expected $version):"
mismatches=()
check_version() { # <label> <file> <value>
  printf '  %-32s %-38s %s\n' "$1" "$2" "${3:-<not found>}"
  [ "$3" = "$version" ] || mismatches+=("$2 has ${3:-no version} (expected $version)")
}
check_version "Microsandbox::VERSION" "$version_rb" "$sdk_version"
check_version "[package] version" "$cargo_toml" "$cargo_version"
check_version "Microsandbox::Binaries::VERSION" "$binaries_rb" "$binaries_version"
if [ "${#mismatches[@]}" -gt 0 ]; then
  for mismatch in "${mismatches[@]}"; do echo "  mismatch: $mismatch" >&2; done
  fail "the version constants at $tag do not all equal $version — bump the file(s) above and re-tag"
fi

# 4. The tagged commit must already be on main.
git fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main" ||
  fail "could not fetch origin main"
git merge-base --is-ancestor "$sha" refs/remotes/origin/main ||
  fail "commit $sha ($tag) is not on origin/main — release tags must point at a commit on main (in CI this also needs a full-history checkout, fetch-depth: 0)"
echo "commit $sha is on origin/main"

# 5. CI must be green for exactly this commit. Wait for the run to appear and
#    finish; a completed run that is not `success` fails at once.
command -v gh >/dev/null || fail "the gh CLI is required for the CI check"
deadline=$((SECONDS + wait_seconds))
gh_errors=0
run_id=""
run_url=""
while :; do
  state="no CI push run for this commit yet"
  if line="$(gh run list --workflow CI --commit "$sha" --event push --limit 50 \
    --json databaseId,status,conclusion,url,createdAt \
    --jq 'sort_by(.createdAt, .databaseId) | (last // empty)
          | [(.databaseId | tostring), .status, (if (.conclusion // "") == "" then "-" else .conclusion end), .url]
          | @tsv')"; then
    gh_errors=0
    if [ -n "$line" ]; then
      IFS=$'\t' read -r run_id run_status run_conclusion run_url <<<"$line"
      if [ "$run_status" = "completed" ]; then
        [ "$run_conclusion" = "success" ] ||
          fail "CI run $run_id for $sha concluded '$run_conclusion', not success: $run_url"
        break
      fi
      state="CI run $run_id is $run_status ($run_url)"
    fi
  else
    gh_errors=$((gh_errors + 1))
    [ "$gh_errors" -lt 5 ] || fail "gh run list failed $gh_errors times in a row (check GH_TOKEN / GH_REPO / actions:read)"
    state="gh run list failed (attempt $gh_errors)"
  fi

  if [ "$SECONDS" -ge "$deadline" ]; then
    fail "timed out after ${wait_seconds}s waiting for the CI push run of $sha to succeed — last state: $state. (CI runs only for the head commit of a push to main, so a release tag must point at such a commit.)"
  fi
  echo "waiting for CI: $state — next check in ${poll_seconds}s ($((deadline - SECONDS))s left)"
  sleep "$poll_seconds"
done
echo "CI run $run_id for $sha succeeded: $run_url"

echo "preflight ok: $tag -> $sha ci run $run_id"
