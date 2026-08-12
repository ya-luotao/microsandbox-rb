# The `gem exec` / clean-machine hole, demonstrated

Companion evidence for issue #1305 (the `microsandbox` + `microsandbox-binaries`
two-gem split for Ruby). Everything below was produced by
[`demo/gem_exec_127.sh`](demo/gem_exec_127.sh) on a clean environment:
throwaway `GEM_HOME`/`GEM_PATH`, empty `MSB_HOME`, and a sanitized `PATH` with
no `msb` anywhere — i.e. the exact state `gem exec` (RubyGems' `npx`
equivalent) creates on a machine that has never seen microsandbox.

The prototype under test is `microsandbox-rb`, a Ruby gem wrapping the
microsandbox core crate, extended with the #1305 design: a
`microsandbox-rb-binaries` companion gem (platform gem vendoring `msb` +
`libkrunfw` from the v0.6.8 release, sha256-verified against the release's
`checksums.sha256`; plus an empty `ruby`-platform fallback), a resolver tier
for it, and a warn-only per-tier `msb --version` check.

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

## Scenario A — proposed design, no auto-provision

Binaries gem not installed (nothing depends on it), auto-provision disabled to
model an SDK that never had it. The resolver falls through every tier
(`MSB_PATH` env → SDK path → `~/.microsandbox` → PATH) and the user gets the
127:

```text
--- installed gems (note: no binaries gem — nothing depends on it):
microsandbox-rb (0.12.0)
--- SDK cannot resolve a runtime:
[microsandbox] could not resolve an msb runtime binary: msb binary not found.
Run `cargo clean -p microsandbox && cargo build` to reinstall, or set MSB_PATH
to the binary location
FAILED: Microsandbox::Error: msb binary not found. Run `cargo clean -p
microsandbox && cargo build` to reinstall, or set MSB_PATH to the binary location
--- and the shell agrees (the classic 127):
sh: msb: command not found
exit code: 127
```

Note what the errors say. The shell gives the classic `command not found`
(exit 127). The SDK-level error is worse than decent: the core's "not found"
message tells a *gem* user to run **`cargo clean -p microsandbox && cargo
build`** — advice from the Rust-workspace world that means nothing in a Ruby
install. Neither message can say "install microsandbox-binaries", because
nothing in the system knows that gem exists.

## Scenario B — auto-provision as the backstop (microsandbox-rb today)

Identical clean machine, auto-provision left on. First use downloads the
release bundle into `MSB_HOME` and proceeds:

```text
[microsandbox] runtime (msb + libkrunfw) not found; downloading to
~/.microsandbox (set MICROSANDBOX_NO_AUTO_INSTALL to skip)...
resolved: …/msbhome-b/bin/msb
msb 0.6.8
```

This is the npx-parity answer: presence is guaranteed by the SDK itself, not
by hoping a second gem got installed.

## Scenario C — the two-gem design working as intended

Binaries platform gem installed alongside the SDK gem, auto-provision OFF.
The runtime comes from the gem's vendored binaries; nothing is downloaded at
runtime; the `msb` executable is owned by the binaries gem (the SDK gem ships
no executables, so the two can never collide on a binstub):

```text
installed microsandbox-rb-binaries-0.12.0-arm64-darwin.gem
resolved: …/gemhome/gems/microsandbox-rb-binaries-0.12.0-arm64-darwin/vendor/bin/msb
msb 0.6.8
--- nothing was downloaded at runtime (MSB_HOME still empty):
       0
--- and the msb executable is owned by the binaries gem (binstub):
msb 0.6.8
```

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
  edge** — the runtime check above is the only backstop that actually fires.
  (A hard `= X.Y.Z` dependency edge from SDK gem to binaries gem *would*
  enforce it and would also close the `gem exec` hole via the empty fallback —
  at the cost of making the ~25 MB download mandatory for everyone. Worth an
  explicit decision either way.)
