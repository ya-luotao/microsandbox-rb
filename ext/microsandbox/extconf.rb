# frozen_string_literal: true

require "mkmf"
require "rb_sys/mkmf"

# Builds the Rust cdylib and installs it as lib/microsandbox/microsandbox.{bundle,so}.
# The Cargo profile is selected via the RB_SYS_CARGO_PROFILE env var (defaults to
# release for installed gems, dev for `rake compile`).
#
# Cargo features for the embedded microsandbox runtime (e.g. "ssh") are enabled
# directly on the dependency in ext/microsandbox/Cargo.toml, mirroring the official
# Python/Node SDKs. The crate's "prebuilt" default feature provisions the msb
# runtime + libkrunfw into ~/.microsandbox at build time.
create_rust_makefile("microsandbox/microsandbox_rb")
