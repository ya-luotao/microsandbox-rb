#!/bin/sh
# Self-verifying clean-machine demo for upstream #1305: what happens when a
# user provisions the SDK gem on a host that has never seen microsandbox
# (empty GEM_HOME, isolated HOME, empty MSB_HOME, no msb on PATH) — the state
# `gem exec` (RubyGems' npx equivalent) always creates, because `gem exec`
# installs the requested gem and its HARD dependencies only, and the binaries
# companion gem is deliberately not a hard dependency.
#
# Scenario A — proposed upstream design (SDK gem + binaries gem, no
#              auto-provision): the binaries gem never arrives on its own, the
#              resolver falls through every tier, and the #1305-agreed
#              `gem exec microsandbox -- run <image>` surface exits 127.
# Scenario B — microsandbox-rb today (auto-provision on first use): the same
#              clean machine bootstraps itself.
# Scenario C — binaries gem installed (the two-gem design working as
#              intended): the runtime comes from the gem, nothing is
#              downloaded at runtime, and the agreed `gem exec` surface works.
#
# EVERY claim below is asserted (exit codes, winner paths, versions, empty
# dirs); any assertion failure exits nonzero. Success criterion for B/C is
# "runtime resolvable + version-matched", not a VM boot — the demo host cannot
# boot microVMs (environment-gated), and the resolver/packaging layer is what
# #1305 is about; scenario C's delegated command is `--version`, never `run`.
#
# Prereqs: freshly built artifacts — `gem build microsandbox-rb.gemspec` at the
# repo root, `rake vendor build:platform` in binaries-gem/ (see its README) —
# plus Rust >= 1.91 for the source-gem native build and network for
# rubygems.org deps + scenario B's runtime download.
set -eu

# ---------- assertion helpers ------------------------------------------------
FAILED=0
fail() { echo "ASSERT FAIL: $*" >&2; FAILED=1; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (got '$1', want '$2')"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3 (output does not contain '$2')";; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3 (output unexpectedly contains '$2')";; *) ;; esac; }

# ---------- clean room -------------------------------------------------------
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BINGEM_DIR="$ROOT/binaries-gem"

# Exact artifact versions, derived from the source of truth — never "first
# matching file" (a stale artifact must fail loudly, not get demoed).
GEM_V=$(sed -n 's/^  VERSION = "\(.*\)"/\1/p' "$ROOT/lib/microsandbox/version.rb")
RUNTIME_V=$(sed -n 's/^  RUNTIME_VERSION = "v\(.*\)"/\1/p' "$ROOT/lib/microsandbox/version.rb")
[ -n "$GEM_V" ] && [ -n "$RUNTIME_V" ] || fail "could not parse versions from lib/microsandbox/version.rb"
SDK_GEM="$ROOT/microsandbox-rb-$GEM_V.gem"
PLATFORM_GEM="$BINGEM_DIR/microsandbox-rb-binaries-$GEM_V-arm64-darwin.gem"
[ -f "$SDK_GEM" ] || fail "missing artifact $SDK_GEM — run: gem build microsandbox-rb.gemspec"
[ -f "$PLATFORM_GEM" ] || fail "missing artifact $PLATFORM_GEM — run: rake vendor build:platform in binaries-gem/"
[ -f "$BINGEM_DIR/vendor/bin/msb" ] && [ -f "$BINGEM_DIR/vendor/lib/libkrunfw.5.dylib" ] ||
  fail "missing vendor tree — run: rake vendor in binaries-gem/ (needed to seed the build-time runtime cache)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/msb-127-demo.XXXXXX")
REAL_HOME="$HOME"

# Isolate HOME BEFORE anything installs: the source gem's native build (core
# crate `prebuilt` feature) provisions ~/.microsandbox at BUILD time, and gem
# reads ~/.gemrc — neither may touch or read the operator's real home. The
# Rust build cache stays shared (CARGO_HOME/RUSTUP_HOME point back) — build
# speed only, invisible to the design under test.
export HOME="$WORK/home"
mkdir -p "$HOME"
export CARGO_HOME="$REAL_HOME/.cargo" RUSTUP_HOME="$REAL_HOME/.rustup"
# Build-time runtime cache: the source gem's native build (core `prebuilt`
# feature) provisions $HOME/.microsandbox at BUILD time, downloading the
# release bundle when it is absent. Pre-seed the isolated HOME from the
# binaries gem's vendor tree — the same release bytes, sha256-verified against
# the release's checksums.sha256 by `rake vendor` — so the build does not
# gamble on GitHub availability. Invisible to the scenarios: each one exports
# its own fresh MSB_HOME, which the resolver's home tier uses instead of
# $HOME/.microsandbox.
mkdir -p "$HOME/.microsandbox/bin" "$HOME/.microsandbox/lib"
cp "$BINGEM_DIR/vendor/bin/msb" "$HOME/.microsandbox/bin/msb"
cp "$BINGEM_DIR/vendor/lib/libkrunfw.5.dylib" "$HOME/.microsandbox/lib/libkrunfw.5.dylib"
export GEM_HOME="$WORK/gemhome" GEM_PATH="$WORK/gemhome"
unset RUBYOPT BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG GEMRC 2>/dev/null || true
unset MSB_PATH MSB_HOME MICROSANDBOX_NO_AUTO_INSTALL 2>/dev/null || true

# Keep ruby + the Rust toolchain reachable, drop everything else so no stray
# msb can leak in. ($REAL_HOME/.local/bin carries this host's mise version
# manager, whose rubygems post-install plugin shells out to `mise` — a local
# toolchain artifact, not part of the design under test; the dir ships no msb.)
RUBY_BIN=$(dirname "$(command -v ruby)")
export PATH="$RUBY_BIN:$REAL_HOME/.cargo/bin:$REAL_HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
command -v msb >/dev/null 2>&1 && fail "msb still on the sanitized PATH ($(command -v msb))"

# Offline gemrc for every `gem exec` call: gem exec has no --source flag, so
# point its config at an empty file:// source — it can then never fetch
# anything from the network, only use what is already installed.
printf ':sources:\n- "file://%s/empty-src/"\n' "$WORK" > "$WORK/gemrc"

step() { printf '\n=== %s\n' "$*"; }

step "0. install the SDK gem into the empty GEM_HOME (source gem: compiles the native ext)"
out=$(gem install "$SDK_GEM" --no-document 2>&1) || { echo "$out"; fail "SDK gem install failed"; }
echo "$out" | tail -2
assert_contains "$out" "Successfully installed microsandbox-rb-$GEM_V" "SDK gem installed"
# Local-toolchain workaround, unrelated to the design under test: on this
# Darwin 27 host, rb_sys stamps an empty LC_ID_DYLIB into the built extension
# and dlopen rejects it — re-stamp and re-sign. (Tracked separately.)
BUNDLE=$(ls "$GEM_HOME"/gems/microsandbox-rb-"$GEM_V"/lib/microsandbox/microsandbox_rb.bundle)
install_name_tool -id microsandbox_rb.bundle "$BUNDLE" && codesign -f -s - "$BUNDLE"

step "0b. gem exec resolves executable names to GEM names — it can never reach the binaries gem"
# `gem exec msb` tries to install a gem NAMED "msb" (a squattable name on
# rubygems.org!), not microsandbox-rb-binaries. Offline gemrc → no fetch.
out=$(gem exec --config-file "$WORK/gemrc" msb --version 2>&1) && rc=0 || rc=$?
echo "$out" | head -1
assert_contains "$out" "Could not find a valid gem 'msb'" "gem exec resolves 'msb' to a gem name"
[ "$rc" -ne 0 ] || fail "gem exec msb unexpectedly succeeded"

step "A. proposed design, clean machine: no binaries gem, auto-provision disabled"
export MSB_HOME="$WORK/msbhome-a"
mkdir -p "$MSB_HOME"
echo "--- installed gems (note: no binaries gem — nothing depends on it):"
listing=$(gem list 2>&1 | grep -i microsandbox || true)
echo "$listing"
assert_contains "$listing" "microsandbox-rb ($GEM_V)" "SDK gem visible"
assert_not_contains "$listing" "microsandbox-rb-binaries" "binaries gem absent (no dependency edge)"

echo "--- SDK cannot resolve a runtime:"
out=$(MICROSANDBOX_NO_AUTO_INSTALL=1 ruby -e '
  require "microsandbox"
  begin
    Microsandbox.ensure_runtime!
    puts "resolved: #{Microsandbox.runtime_path}"
  rescue => e
    puts "FAILED: #{e.class}: #{e.message}"
  end
' 2>&1)
echo "$out"
assert_contains "$out" "FAILED: Microsandbox::Error" "SDK-level resolution fails"
assert_contains "$out" "msb binary not found" "SDK error names the missing runtime"
assert_not_contains "$out" "resolved:" "resolution must NOT succeed in scenario A"

echo "--- the #1305-agreed surface, gem exec microsandbox -- run <image>:"
# Resolution-failure precondition asserted above, so this can only hit the
# shim's 127 path — it can never reach an actual `msb run` (which would boot a
# VM). Our prototype gem is named microsandbox-rb while the exe is
# microsandbox, so -g bridges the two; the official gem's name and exe
# coincide and need no -g.
out=$(MICROSANDBOX_NO_AUTO_INSTALL=1 gem exec --config-file "$WORK/gemrc" --conservative \
  -g microsandbox-rb microsandbox -- run alpine 2>&1) && rc=0 || rc=$?
echo "$out"
assert_eq "$rc" "127" "gem exec surface exits 127 on the clean machine"
assert_contains "$out" "no msb runtime found" "shim explains the failure"

echo "--- and the bare shell agrees (the classic 127):"
out=$(msb --version 2>&1) && rc=0 || rc=$?
echo "$out"
assert_eq "$rc" "127" "bare msb is command-not-found"

step "B. microsandbox-rb today, same clean machine: auto-provision bootstraps"
export MSB_HOME="$WORK/msbhome-b"
mkdir -p "$MSB_HOME"
out=$(ruby -e '
  require "microsandbox"
  Microsandbox.ensure_runtime!   # downloads the runtime bundle into MSB_HOME
  puts "resolved: #{Microsandbox.runtime_path}"
' 2>&1)
echo "$out"
resolved=$(echo "$out" | sed -n 's/^resolved: //p')
case "$resolved" in
  "$MSB_HOME"/*) ;;
  *) fail "scenario B winner should live under MSB_HOME (got '$resolved')" ;;
esac
ver=$("$resolved" --version) || fail "provisioned msb does not run"
assert_eq "$ver" "msb $RUNTIME_V" "provisioned msb reports the embedded runtime version"

step "C. two-gem design as intended: binaries gem installed, auto-provision OFF"
export MSB_HOME="$WORK/msbhome-c"
mkdir -p "$MSB_HOME"
out=$(gem install --local "$PLATFORM_GEM" --no-document 2>&1) || { echo "$out"; fail "binaries gem install failed"; }
assert_contains "$out" "Successfully installed microsandbox-rb-binaries-$GEM_V-arm64-darwin" "binaries gem installed"
echo "installed microsandbox-rb-binaries-$GEM_V-arm64-darwin"

out=$(MICROSANDBOX_NO_AUTO_INSTALL=1 ruby -e '
  require "microsandbox"
  Microsandbox.ensure_runtime!
  puts "resolved: #{Microsandbox.runtime_path}"
' 2>&1)
echo "$out"
resolved=$(echo "$out" | sed -n 's/^resolved: //p')
case "$resolved" in
  "$GEM_HOME"/gems/microsandbox-rb-binaries-*/vendor/bin/msb) ;;
  *) fail "scenario C winner should be the gem-vendored msb (got '$resolved')" ;;
esac
ver=$("$resolved" --version) || fail "vendored msb does not run"
assert_eq "$ver" "msb $RUNTIME_V" "vendored msb reports the embedded runtime version"

echo "--- nothing was downloaded at runtime (MSB_HOME still empty):"
count=$(find "$MSB_HOME" -type f | wc -l | tr -d ' ')
echo "files under MSB_HOME: $count"
assert_eq "$count" "0" "no runtime download happened in scenario C"

echo "--- the msb executable is owned by the binaries gem (binstub):"
ver=$("$GEM_HOME/bin/msb" --version) || fail "binaries-gem msb binstub does not run"
echo "$ver"
assert_eq "$ver" "msb $RUNTIME_V" "binstub delegates to the vendored msb"

echo "--- and the agreed gem exec surface works end to end (delegating --version, never run):"
out=$(MICROSANDBOX_NO_AUTO_INSTALL=1 gem exec --config-file "$WORK/gemrc" --conservative \
  -g microsandbox-rb microsandbox -- --version 2>&1) && rc=0 || rc=$?
echo "$out"
assert_eq "$rc" "0" "gem exec surface succeeds with the binaries gem installed"
assert_contains "$out" "msb $RUNTIME_V" "gem exec surface delegates to the vendored msb"

step "ALL ASSERTIONS PASSED — artifacts in $WORK"
