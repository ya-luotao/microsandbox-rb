# microsandbox-rb-binaries (prototype)

Prototype of the two-gem split proposed in upstream issue
[#1305](https://github.com/superradcompany/microsandbox/issues/1305): a
companion gem that ships the prebuilt `msb` microVM runtime + `libkrunfw`
firmware per platform, so the `microsandbox-rb` SDK gem never downloads them at
first use.

**Not published to rubygems.org.** Local `gem build` / `gem install --local`
only — this exists to produce evidence for the #1305 design discussion. See
`DEMO.md` for the clean-machine `gem exec` experiment and the lane report for
the full findings.

## Layout

- `lib/microsandbox_rb_binaries.rb` — the discovery API the SDK gem consumes:
  `MicrosandboxRbBinaries.msb_path` / `.libkrunfw_path`, both `nil` on the
  fallback variant.
- `exe/msb` — the `msb` executable is owned by THIS gem (the SDK gem ships no
  executables), so the two gems cannot collide on a binstub.
- `vendor/{bin,lib}` — populated by `rake vendor` (gitignored, ~30 MB).

## Building

```sh
rake vendor          # download + sha256-verify (fail-closed) + stage binaries
rake build:platform  # microsandbox-rb-binaries-<v>-arm64-darwin.gem
rake build:ruby      # microsandbox-rb-binaries-<v>.gem (empty fallback, no exe)
```

## Versioning (lockstep)

`VERSION` tracks the microsandbox-rb gem version; `RUNTIME_VERSION` names the
upstream release the binaries came from. There is deliberately **no dependency
edge** between the two gems, so drift is only caught at runtime: the SDK runs
`msb --version` against whatever its resolver picks and warns on mismatch.
