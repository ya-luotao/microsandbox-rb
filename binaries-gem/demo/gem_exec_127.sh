#!/bin/sh
# Clean-machine demo for upstream #1305: what happens when a user provisions
# the SDK gem on a host that has never seen microsandbox (empty GEM_HOME, empty
# MSB_HOME, no msb on PATH) — the situation `gem exec` (RubyGems' npx
# equivalent) always creates, because `gem exec` installs the requested gem and
# its HARD dependencies only, and the binaries companion gem is deliberately
# not a hard dependency.
#
# Scenario A — proposed upstream design (SDK gem + binaries gem, no
#              auto-provision): binaries gem never arrives on its own, the
#              resolver falls through to PATH, and the user gets exit 127 /
#              "no msb anywhere".
# Scenario B — microsandbox-rb today (auto-provision on first use): the same
#              clean machine bootstraps itself.
# Scenario C — binaries gem installed (the two-gem design working as intended):
#              no auto-provision needed, runtime comes from the gem, nothing is
#              downloaded at runtime.
#
# Success criterion for B/C is "runtime resolvable + version-matched", not a
# VM boot — the demo host cannot boot microVMs (environment-gated), and the
# resolver/packaging layer is what #1305 is about.
#
# Run from anywhere; artifacts land in a mktemp dir printed at the end.
# Prereqs: `gem build` outputs present (repo root microsandbox-rb-<v>.gem,
# binaries-gem/*.gem — see binaries-gem/README.md), Rust >= 1.91 for the
# source-gem native build, network for rubygems.org deps + scenario B's
# runtime download.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BINGEM_DIR="$ROOT/binaries-gem"
SDK_GEM=$(ls "$ROOT"/microsandbox-rb-[0-9]*.gem | head -1)
PLATFORM_GEM=$(ls "$BINGEM_DIR"/microsandbox-rb-binaries-*-arm64-darwin.gem | head -1)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/msb-127-demo.XXXXXX")
export GEM_HOME="$WORK/gemhome" GEM_PATH="$WORK/gemhome"

# Keep ruby + the Rust toolchain reachable, drop everything else so no stray
# msb can leak in. Fail fast if msb is somehow still visible. ($HOME/.local/bin
# carries this host's mise version manager, whose rubygems post-install plugin
# shells out to `mise` — a local toolchain artifact, not part of the design
# under test; the dir ships no msb.)
RUBY_BIN=$(dirname "$(command -v ruby)")
export PATH="$RUBY_BIN:$HOME/.cargo/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if command -v msb >/dev/null 2>&1; then
  echo "ABORT: msb still on the sanitized PATH ($(command -v msb))" >&2
  exit 1
fi
unset MSB_PATH MICROSANDBOX_NO_AUTO_INSTALL 2>/dev/null || true

step() { printf '\n=== %s\n' "$*"; }

step "0. install the SDK gem into an empty GEM_HOME (source gem: compiles the native ext)"
time gem install "$SDK_GEM" --no-document 2>&1 | tail -2
# Local-toolchain workaround, unrelated to the design under test: on this
# Darwin 27 host, rb_sys stamps an empty LC_ID_DYLIB into the built extension
# and dlopen rejects it — re-stamp and re-sign. (Tracked separately.)
BUNDLE=$(ls "$GEM_HOME"/gems/microsandbox-rb-*/lib/microsandbox/microsandbox_rb.bundle)
install_name_tool -id microsandbox_rb.bundle "$BUNDLE" && codesign -f -s - "$BUNDLE"

step "0b. gem exec resolves executable names to GEM names — it can never reach the binaries gem"
# `gem exec msb` would try to install a gem NAMED "msb" (a squattable name on
# rubygems.org!), not microsandbox-rb-binaries. gem exec has no --source flag,
# so point its config at an empty file:// source so nothing is fetched from
# the network:
printf ':sources:\n- "file://%s/empty-src/"\n' "$WORK" > "$WORK/gemrc"
gem exec --config-file "$WORK/gemrc" msb --version 2>&1 | head -1 || true

step "A. proposed design, clean machine: no binaries gem, auto-provision disabled"
export MSB_HOME="$WORK/msbhome-a" && mkdir -p "$MSB_HOME"
echo "--- installed gems (note: no binaries gem — nothing depends on it):"
gem list | grep -i microsandbox || true
echo "--- SDK cannot resolve a runtime:"
MICROSANDBOX_NO_AUTO_INSTALL=1 ruby -e '
  require "microsandbox"
  begin
    Microsandbox.ensure_runtime!
    puts "resolved: #{Microsandbox.runtime_path}"
  rescue => e
    puts "FAILED: #{e.class}: #{e.message}"
  end
'
echo "--- and the shell agrees (the classic 127):"
msb --version 2>&1 || echo "exit code: $?"

step "B. microsandbox-rb today, same clean machine: auto-provision bootstraps"
export MSB_HOME="$WORK/msbhome-b" && mkdir -p "$MSB_HOME"
ruby -e '
  require "microsandbox"
  Microsandbox.ensure_runtime!   # downloads the runtime bundle into MSB_HOME
  path = Microsandbox.runtime_path
  puts "resolved: #{path}"
  system(path, "--version")
'

step "C. two-gem design as intended: binaries gem installed, auto-provision OFF"
export MSB_HOME="$WORK/msbhome-c" && mkdir -p "$MSB_HOME"
gem install --local "$PLATFORM_GEM" --no-document >/dev/null && echo "installed $(basename "$PLATFORM_GEM")"
MICROSANDBOX_NO_AUTO_INSTALL=1 ruby -e '
  require "microsandbox"
  Microsandbox.ensure_runtime!
  path = Microsandbox.runtime_path
  puts "resolved: #{path}"
  system(path, "--version")
'
echo "--- nothing was downloaded at runtime (MSB_HOME still empty):"
find "$MSB_HOME" -type f | wc -l
echo "--- and the msb executable is owned by the binaries gem (binstub):"
"$GEM_HOME/bin/msb" --version

step "done — artifacts in $WORK"
