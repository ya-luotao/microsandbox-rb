# The `gem exec` / clean-machine hole, demonstrated

Companion evidence for issue #1305 (the `microsandbox` + `microsandbox-binaries`
two-gem split for Ruby). Everything below was produced by
[`demo/gem_exec_127.sh`](demo/gem_exec_127.sh) — a **self-verifying** script
(every claimed exit code, winner path, version, and empty directory is
asserted; any assertion failure exits nonzero) — in a clean room: isolated
`HOME`, throwaway `GEM_HOME`/`GEM_PATH`, empty `MSB_HOME`, offline gemrc for
every `gem exec` call, and a sanitized `PATH` with no `msb` anywhere — i.e.
the exact state `gem exec` (RubyGems' `npx` equivalent) creates on a machine
that has never seen microsandbox.

The prototype under test is `microsandbox-rb`, a Ruby gem wrapping the
microsandbox core crate, extended with the #1305 design: a
`microsandbox-rb-binaries` companion gem (platform gem vendoring `msb` +
`libkrunfw` from the v0.6.8 release, sha256-verified against the release's
`checksums.sha256` and revalidated fail-closed at gem build time via a staged
manifest; plus an empty `ruby`-platform fallback), a resolver tier for it, a
warn-only per-tier `msb --version` check (bounded timeout, exit status
required), and a `microsandbox` CLI shim on the SDK gem implementing the
agreed `gem exec microsandbox -- run <image>` surface with node-SDK parity
(resolve through the full ladder, exit 127 when nothing is found).

One naming note for reading the transcripts: this prototype's gem is named
`microsandbox-rb` (the `microsandbox` gem name is taken on rubygems.org)
while the executable is `microsandbox`, so the demo bridges the two with
`gem exec -g microsandbox-rb microsandbox -- …`. The official gem's name and
executable would coincide, making it the literal
`gem exec microsandbox -- run <image>`.

## Why `gem exec` can never save you

Two RubyGems facts combine into the hole:

1. **`gem exec` installs the requested gem and its hard dependencies only.**
   The binaries gem is deliberately *not* a hard dependency (that's the point
   of the split — and a hard dependency edge would also drag ~25 MB onto
   platforms that want to opt out). There is no `optionalDependencies`
   equivalent in RubyGems, which is the mechanism `npx` relies on to make the
   npm version of this design work. So on a clean machine the binaries gem
   **never arrives**, no matter what the user runs.

2. **`gem exec <name>` resolves executable names to *gem* names.** `gem exec
   msb` would try to install a gem literally named `msb` from rubygems.org — a
   squattable name, not `microsandbox-binaries`:

   ```text
   $ gem exec --config-file …/gemrc msb --version   # gemrc: empty file:// source
   ERROR:  Could not find a valid gem 'msb' (>= 0), here is why:
             Unable to download data from file://…/empty-src/ …
   ```

   (Pointed at an empty source so nothing was actually fetched; against the
   real index this resolves to whatever third party owns the `msb` gem name.)

So the failure mode of the split-without-auto-provision design is not
hypothetical — it is the *default* first-run experience:

## The agreed spelling doesn't work: `--` silently drops the arguments

Second RubyGems finding, hit live while wiring up the shim: **the invocation
as written in the issue — `gem exec microsandbox -- run <image>` — does not
work on current RubyGems (3.6.9).** The exec command eats a `--` placed
*after* the command name plus everything behind it, so the delegated binary
runs with an empty argv. Probed with an argv-echoing fake `msb`:

```text
gem exec … microsandbox -- --version   → delegated argv: []          (msb prints its usage)
gem exec … microsandbox --version      → delegated argv: [--version] (works)
gem exec … -- microsandbox --version   → Gem::CommandLineError
```

The working spelling is plain `gem exec microsandbox run <image>` — no `--`.
The demo pins the arg-drop behavior itself as an assertion (scenario C below),
so a future RubyGems change will surface loudly.

## Scenario A — proposed design, no auto-provision

Binaries gem not installed (nothing depends on it), auto-provision disabled to
model an SDK that never had it. The resolver falls through every tier
(`MSB_PATH` env → SDK path → `~/.microsandbox` → PATH), and the agreed surface
— exercised for real, via `gem exec` — exits 127:

```text
--- installed gems (note: no binaries gem — nothing depends on it):
microsandbox-rb (0.12.0)
--- SDK cannot resolve a runtime:
[microsandbox] could not resolve an msb runtime binary: msb binary not found.
Run `cargo clean -p microsandbox && cargo build` to reinstall, or set MSB_PATH
to the binary location
FAILED: Microsandbox::Error: msb binary not found. …
--- the #1305-agreed surface (working spelling), gem exec microsandbox run <image>:
microsandbox: msb binary not found. …
microsandbox: no msb runtime found. Install the microsandbox-rb-binaries gem,
allow first-use auto-provisioning (unset MICROSANDBOX_NO_AUTO_INSTALL), or set
MSB_PATH.
    (exit code 127, asserted)
--- and the bare shell agrees (the classic 127):
msb: command not found
    (exit code 127, asserted)
```

Note what the errors say. The core's "not found" message tells a *gem* user to
run **`cargo clean -p microsandbox && cargo build`** — advice from the
Rust-workspace world that means nothing in a Ruby install. Neither message can
say "install microsandbox-binaries", because nothing in the system knows that
gem exists. (The shim's own message can, and does.)

## Scenario C — the two-gem design working as intended

(Runs before B in the script: C is network-free by design — zero runtime
downloads is its whole claim — so a run on a flaky network still verifies it.)

Binaries platform gem installed alongside the SDK gem, auto-provision OFF.
The runtime comes from the gem's vendored binaries; nothing is downloaded at
runtime; the `msb` executable is owned by the binaries gem; and the agreed
`gem exec` surface works end to end:

```text
installed microsandbox-rb-binaries-0.12.0-arm64-darwin
resolved: …/gemhome/gems/microsandbox-rb-binaries-0.12.0-arm64-darwin/vendor/bin/msb
--- nothing was downloaded at runtime (MSB_HOME still empty):
files under MSB_HOME: 0        (asserted)
--- and the FIRMWARE winner is the companion gem's too (no mixed runtime):
firmware: …/gems/microsandbox-rb-binaries-0.12.0-arm64-darwin/vendor/lib/libkrunfw.5.dylib
                               (asserted — both binaries same-tier)
--- the msb executable is owned by the binaries gem (binstub):
msb 0.6.8
--- and the gem exec surface works end to end (delegating --version, never run):
msb 0.6.8                      (exit 0, asserted)
--- #1305 gotcha, pinned as an assertion: the issue-as-written spelling
--- (gem exec microsandbox -- run <image>) silently DROPS the arguments:
Microsandbox CLI v0.6.8        (msb usage — empty argv — asserted)
```

## Scenario B — auto-provision as the backstop (microsandbox-rb today)

Same clean machine, binaries gem uninstalled again (asserted — it would
otherwise claim the resolver tier and skip the very thing B tests),
auto-provision left on. First use downloads the release bundle into `MSB_HOME`
and proceeds; the download is a plain network operation, retried up to three
times so a flaky CDN doesn't masquerade as a design failure (this very run ate
one CDN hiccup):

```text
auto-provision download attempt 1 failed (network); retrying:
[microsandbox] runtime (msb + libkrunfw) not found; downloading to
~/.microsandbox (set MICROSANDBOX_NO_AUTO_INSTALL to skip)...
resolved: …/msbhome-b/bin/msb
    (path under MSB_HOME + `msb 0.6.8` version, both asserted)
```

This is the npx-parity answer: presence is guaranteed by the SDK itself, not
by hoping a second gem got installed.

Resolver precedence with the gem installed, verified separately (each line is
one fresh process):

```text
(nothing set)                        → …/binaries-gem/vendor/bin/msb   # gem tier wins over ~/.microsandbox
Microsandbox.runtime_path = "/opt/…" → /opt/custom/msb                 # a startup-time user override still wins
MSB_PATH=/env/override/msb           → /env/override/msb               # env wins over everything
```

## Takeaways for #1305

- The binaries gem is a **bandwidth/air-gap optimization**, not a presence
  guarantee. `bundle install`-based projects get it (platform resolution
  works: the platform gem wins where one matches, the empty `ruby` fallback
  keeps `bundle install` green on musl/Windows); `gem exec` and bare
  `gem install microsandbox` users don't.
- **Auto-provision must stay** (as the lowest resolver tier) if "works on a
  clean machine" is a goal. A and B differ by exactly one thing.
- **Per-tier version validation matters**: presence ≠ correctness. Any tier
  (`MSB_PATH`, a user override, a stale `~/.microsandbox`, PATH) can resolve a
  version-mismatched `msb`, and without a check the failure surfaces later as
  an opaque host↔guest protocol error. The prototype runs `msb --version`
  against whatever tier wins and warns on mismatch:

  ```text
  [microsandbox] runtime version mismatch: msb at /…/msb is 0.6.6, but this
  gem embeds runtime 0.6.8 — sandbox operations may fail on a host/guest
  protocol mismatch. Align the runtime with the gem, or remove the override
  that selected it.
  ```

- **Lockstep versioning has no enforcement mechanism without a dependency
  edge** — the runtime check above (plus a gem-to-gem VERSION comparison at
  claim time) is the only backstop that actually fires. (A hard `= X.Y.Z`
  dependency edge from SDK gem to binaries gem *would* enforce it and would
  also close the `gem exec` hole via the empty fallback — at the cost of
  making the ~25 MB download mandatory for everyone. Worth an explicit
  decision either way.)
- **Spell the CLI story without the `--`**: `gem exec microsandbox run
  <image>` works; the `--` variant written in the issue silently drops every
  argument on current RubyGems. Any docs/README produced for the two-gem
  release should use the no-`--` form.
- **The runtime slot needs core support to be a real package tier**: this
  prototype piggybacks the package tier on the single set-once SDK path slot,
  which (a) double-books it against the user override channel (a getter can
  permanently consume the setter's chance — mitigated with a warning, not
  fixable SDK-side) and (b) cannot atomically select msb + libkrunfw together
  (two independent set-once locks can mix runtimes when a user overrides only
  one; the prototype claims only the msb slot and relies on the firmware
  resolving by `../lib` adjacency). A dedicated package tier in the core
  resolver — below the user override, above home/PATH, carrying both paths as
  one unit — removes both problems for every language SDK at once.
