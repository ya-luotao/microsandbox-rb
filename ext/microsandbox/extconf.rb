# frozen_string_literal: true

require "mkmf"
require "rb_sys/mkmf"
require "shellwords"

# Preflight: the embedded microsandbox core is edition 2024 and pulls smoltcp,
# which sets a Minimum Supported Rust Version of 1.91. An older rustc (commonly
# Homebrew's, which shadows a newer rustup on PATH and ignores this gem's
# rust-toolchain.toml) fails deep in the build with a cryptic "rustc X is not
# supported by smoltcp" error. Detect it up front and explain the fix instead.
#
# Probe the *same* rustc the build will invoke. create_rust_makefile drives the
# build through `cargo`, and cargo resolves its compiler exactly as: the `RUSTC`
# env var if set, otherwise the bare `rustc` found on PATH. It does NOT use the
# `rustc` sitting beside the `cargo` binary, and the rustup `cargo` shim neither
# sets `RUSTC` nor prepends its toolchain bin to PATH — toolchain selection
# survives only because the PATH `rustc` is normally itself a rustup shim that
# honors rust-toolchain.toml. So a non-rustup rustc earlier on PATH (which reads
# neither RUSTUP_TOOLCHAIN nor the toolchain file) is what the build actually
# runs. Mirroring cargo's RUSTC-then-PATH resolution is the only probe that
# neither false-passes (the trap of checking the cargo sibling, which stays a
# valid rustup shim while the build silently uses the stale PATH rustc) nor
# false-aborts (when `RUSTC` points at a newer compiler than the PATH `rustc`).
MSRV = Gem::Version.new("1.91")

def build_rustc
  rustc = ENV["RUSTC"].to_s.strip
  rustc.empty? ? "rustc" : rustc
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

      • Or point `RUSTC` at a recent compiler (cargo honors it over PATH):
          RUSTC="$HOME/.cargo/bin/rustc" gem install microsandbox-rb

    (This gem ships a rust-toolchain.toml pinning `stable`, but only a rustup
    `rustc` shim reads it — a non-rustup `rustc` ahead on PATH ignores it, and
    cargo invokes that PATH `rustc` unless `RUSTC` says otherwise.)
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
