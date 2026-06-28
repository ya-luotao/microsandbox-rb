# frozen_string_literal: true

require "mkmf"
require "rb_sys/mkmf"
require "shellwords"

# Preflight: the embedded microsandbox core is edition 2024 and pulls smoltcp,
# which sets a Minimum Supported Rust Version of 1.91. A `cargo` from an older
# toolchain (commonly Homebrew's rustc, which shadows a newer rustup on PATH and
# ignores this gem's rust-toolchain.toml) fails deep in the build with a cryptic
# "rustc X is not supported by smoltcp" error. Detect it up front and explain
# the fix instead.
#
# Probe the rustc the BUILD will actually use — not whichever rustc happens to
# be first on PATH. create_rust_makefile drives the build through `cargo` (the
# Makefile's `CARGO ?= cargo`, so the `CARGO` env var if set — e.g. a
# cross-compile wrapper — else the `cargo` resolved on PATH), and cargo invokes
# the `rustc` that sits alongside it: a rustup `cargo` shim and its sibling
# `rustc` shim both honor this gem's rust-toolchain.toml (pinning `stable`),
# while a Homebrew `cargo`+`rustc` pair both ignore it. So a bare `rustc
# --version` can false-abort a build that would succeed (a non-rustup rustc
# shadowing a rustup `cargo` shim) — yet still correctly catch the real too-old
# case. Resolving the rustc beside the build's `cargo`, from this same directory
# (so the toolchain override is discovered the way the build discovers it),
# mirrors both cases.
MSRV = Gem::Version.new("1.91")

def build_rustc
  cargo = ENV["CARGO"].to_s
  cargo = `command -v cargo 2>/dev/null`.strip if cargo.empty?
  sibling = File.join(File.dirname(cargo), "rustc") unless cargo.empty?
  (sibling && File.exist?(sibling)) ? sibling : "rustc"
rescue
  "rustc"
end

rustc = build_rustc
rustc_version = begin
  out = `#{rustc.shellescape} --version 2>/dev/null`
  out[/\d+\.\d+(\.\d+)?/] && Gem::Version.new(out[/\d+\.\d+(\.\d+)?/])
rescue
  nil
end

if rustc_version && rustc_version < MSRV
  abort(<<~MSG)

    [microsandbox-rb] Rust #{rustc_version} is too old — the embedded core requires rustc >= #{MSRV}.
      Found: #{rustc} (#{rustc_version})

    This usually means an older rustc (e.g. Homebrew's) is ahead of a newer
    rustup toolchain on your PATH. Fixes:

      • Put rustup's toolchain first for the install:
          PATH="$HOME/.cargo/bin:$PATH" gem install microsandbox-rb
      • Or make a recent stable the default and ensure no other rustc shadows it:
          rustup install stable && rustup default stable
      • Or upgrade your system Rust to >= #{MSRV}.

    (This gem ships a rust-toolchain.toml pinning `stable`; the rustup `cargo`
    shim honors it, but a non-rustup `cargo` does not.)
  MSG
end

# Builds the Rust cdylib and installs it as lib/microsandbox/microsandbox.{bundle,so}.
# The Cargo profile is selected via the RB_SYS_CARGO_PROFILE env var (defaults to
# release for installed gems, dev for `rake compile`).
#
# Cargo features for the embedded microsandbox runtime (e.g. "ssh") are enabled
# directly on the dependency in ext/microsandbox/Cargo.toml, mirroring the official
# Python/Node SDKs. The crate's "prebuilt" default feature provisions the msb
# runtime + libkrunfw into ~/.microsandbox at build time.
create_rust_makefile("microsandbox/microsandbox_rb")
