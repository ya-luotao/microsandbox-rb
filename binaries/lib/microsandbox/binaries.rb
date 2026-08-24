# frozen_string_literal: true

module Microsandbox
  # Companion gem `microsandbox-rb-binaries`: ships the prebuilt `msb` microVM
  # runtime and the `libkrunfw` firmware for one platform under `vendor/`, so the
  # `microsandbox-rb` SDK gem never has to download them at first use.
  #
  # Published as one gem per supported platform (`arm64-darwin`,
  # `x86_64-linux-gnu`, `aarch64-linux-gnu`), in lockstep with `microsandbox-rb`
  # — install both at the same version. There is no dependency edge in either
  # direction: the SDK discovers this gem at load time (`require
  # "microsandbox/binaries"`), checks {RUNTIME_VERSION} against the runtime it
  # was built for, and only then points the core resolver at {msb_path}.
  # `MSB_PATH` (environment) still outranks it. Without this gem the SDK falls
  # back to its first-use download into `~/.microsandbox`.
  #
  # The vendored layout mirrors the upstream release bundle and `~/.microsandbox`
  # (`bin/msb` + `lib/libkrunfw.*`): the core resolver finds the firmware by
  # `../lib` adjacency to `msb`, so only the binary path needs handing over.
  module Binaries
    # Gem version — kept in lockstep with `Microsandbox::VERSION` (asserted by
    # the SDK's spec/unit/version_spec.rb).
    VERSION = "0.14.0"

    # The upstream microsandbox release the vendored binaries come from. Must
    # equal the SDK's `Microsandbox::RUNTIME_VERSION` for the SDK to use them.
    RUNTIME_VERSION = "v0.6.11"

    # Directory holding the vendored runtime (`bin/`, `lib/`, `manifest.json`).
    ROOT = File.expand_path("../../vendor", __dir__)

    # Name of the manifest `rake vendor` writes next to the binaries.
    MANIFEST = "manifest.json"

    class << self
      # @return [String] absolute path of the vendored runtime directory
      def root
        ROOT
      end

      # @return [String, nil] absolute path to the vendored `msb` binary, or nil
      #   when this install carries no runtime (e.g. a checkout without
      #   `rake vendor`).
      def msb_path
        path = File.join(ROOT, "bin", "msb")
        File.file?(path) ? path : nil
      end

      # @return [String, nil] absolute path to the vendored `libkrunfw` shared
      #   library. The filename is platform-specific (`libkrunfw.5.dylib`,
      #   `libkrunfw.so.5.6.1`, …), so it is globbed rather than hardcoded.
      def libkrunfw_path
        Dir[File.join(ROOT, "lib", "libkrunfw*")].sort.find { |f| File.file?(f) }
      end

      # @return [Boolean] whether both `msb` and `libkrunfw` are present
      def available?
        !msb_path.nil? && !libkrunfw_path.nil?
      end

      # The manifest written by `rake vendor` (platform, runtime version, bundle
      # digest, per-file sha256). Informational at runtime — integrity is
      # enforced when the gem is built.
      # @return [Hash, nil]
      def manifest
        path = File.join(ROOT, MANIFEST)
        return nil unless File.file?(path)
        require "json"
        JSON.parse(File.read(path))
      end

      # @return [String, nil] the RubyGems platform this gem was built for
      def platform
        manifest&.fetch("platform", nil)
      end
    end
  end
end
