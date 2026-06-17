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
require_relative "microsandbox/exec_handle"
require_relative "microsandbox/fs"
require_relative "microsandbox/metrics"
require_relative "microsandbox/log_entry"
require_relative "microsandbox/streams"
require_relative "microsandbox/image"
require_relative "microsandbox/volume"
require_relative "microsandbox/snapshot"
require_relative "microsandbox/patch"
require_relative "microsandbox/network"
require_relative "microsandbox/agent"
require_relative "microsandbox/ssh"
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
    # `~/.microsandbox` (idempotent).
    #
    # When the gem is built from source, the native extension provisions the
    # runtime at build time, so this is usually a no-op. Precompiled platform
    # gems (which skip the local Rust build) do NOT provision it that way, so the
    # runtime is fetched on first use — see {ensure_runtime!}. Call this
    # explicitly to provision ahead of time (e.g. while baking a container
    # image) so the first {Sandbox.create} doesn't pay the download.
    # @return [nil]
    def install
      Native.install
      nil
    end

    # @return [Boolean] whether the runtime is installed and resolvable
    def installed?
      Native.installed?
    end

    # Ensure the `msb` runtime + `libkrunfw` are present, provisioning them on
    # first use if not. Called automatically by {Sandbox.create}/{Sandbox.start}
    # so precompiled-gem users (who never ran the source build) get a working
    # runtime without a manual {install} step.
    #
    # The download is attempted at most once per process. Opt out by setting
    # `MICROSANDBOX_NO_AUTO_INSTALL` (e.g. air-gapped hosts that provision the
    # runtime out of band); the subsequent operation then surfaces the missing
    # runtime itself. Already-installed runtimes (e.g. source builds) skip
    # straight through with only a cheap presence check.
    # @return [nil]
    def ensure_runtime!
      return if @runtime_ready
      if installed?
        @runtime_ready = true
        return
      end
      return if auto_install_disabled?

      warn "[microsandbox] runtime (msb + libkrunfw) not found; " \
           "downloading to ~/.microsandbox (set MICROSANDBOX_NO_AUTO_INSTALL to skip)..."
      install
      @runtime_ready = true
      nil
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

    # Latest resource-usage snapshot for every running sandbox, keyed by name.
    # Mirrors the official `all_sandbox_metrics`/`allSandboxMetrics` helpers.
    # @return [Hash{String => Metrics}]
    def all_sandbox_metrics
      Native.all_sandbox_metrics.transform_values { |m| Metrics.new(m) }
    end

    private

    # Auto-provisioning is on by default; any non-empty, non-"0"/"false" value
    # of MICROSANDBOX_NO_AUTO_INSTALL disables it.
    def auto_install_disabled?
      v = ENV["MICROSANDBOX_NO_AUTO_INSTALL"]
      !v.nil? && !v.empty? && !%w[0 false no].include?(v.downcase)
    end
  end
end
