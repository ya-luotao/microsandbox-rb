# frozen_string_literal: true

require "mkmf"
require "rb_sys/mkmf"

# Preflight: the embedded microsandbox core is edition 2024 and pulls smoltcp,
# which sets a Minimum Supported Rust Version of 1.91. A `cargo` from an older
# toolchain (commonly Homebrew's rustc, which shadows a newer rustup on PATH and
# ignores this gem's rust-toolchain.toml) fails deep in the build with a cryptic
# "rustc X is not supported by smoltcp" error. Detect it up front and explain
# the fix instead.
MSRV = Gem::Version.new("1.91")
rustc_version = begin
  out = `rustc --version 2>/dev/null`
  out[/\d+\.\d+(\.\d+)?/] && Gem::Version.new(out[/\d+\.\d+(\.\d+)?/])
rescue StandardError
  nil
end

if rustc_version && rustc_version < MSRV
  which_rustc = (`which rustc 2>/dev/null`.strip rescue "")
  abort(<<~MSG)

    [microsandbox-rb] Rust #{rustc_version} is too old — the embedded core requires rustc >= #{MSRV}.
      Found: #{which_rustc.empty? ? "rustc" : which_rustc} (#{rustc_version})

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
