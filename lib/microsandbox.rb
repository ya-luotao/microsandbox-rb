# frozen_string_literal: true

require_relative "microsandbox/version"

# Load the compiled native extension. Precompiled platform gems ship a
# version-specific subdirectory (e.g. lib/microsandbox/3.4/microsandbox_rb.bundle);
# fall back to the flat path used by source builds.
begin
  ruby_version = RbConfig::CONFIG["ruby_version"].to_s
  require_relative "microsandbox/#{ruby_version}/microsandbox_rb"
rescue LoadError
  require_relative "microsandbox/microsandbox_rb"
end

require_relative "microsandbox/errors"
require_relative "microsandbox/exec_output"
require_relative "microsandbox/fs"
require_relative "microsandbox/metrics"
require_relative "microsandbox/log_entry"
require_relative "microsandbox/sandbox"

# Microsandbox — lightweight microVM sandboxes for Ruby.
#
# The runtime is embedded directly in the process via a Rust native extension;
# there is no daemon to install and no server to connect to. Creating a sandbox
# spawns a real microVM as a child process.
#
# @example
#   Microsandbox::Sandbox.create("hello", image: "python") do |sb|
#     puts sb.exec("python", ["-c", "print('Hello, World!')"]).stdout
#   end
module Microsandbox
  class << self
    # @return [String] the gem version
    def version
      VERSION
    end

    # Download and install the `msb` runtime + `libkrunfw` into
    # `~/.microsandbox` (idempotent). Usually unnecessary: the native
    # extension provisions the runtime at build time.
    # @return [nil]
    def install
      Native.install
      nil
    end

    # @return [Boolean] whether the runtime is installed and resolvable
    def installed?
      Native.installed?
    end

    # @return [String] the resolved path to the `msb` runtime binary
    def runtime_path
      Native.resolved_msb_path
    end

    # Override the `msb` runtime path (highest-priority SDK tier of the
    # resolver, below only the `MSB_PATH` environment variable).
    # @param path [String]
    # @return [void]
    def runtime_path=(path)
      Native.set_runtime_msb_path(path.to_s)
    end
  end
end
