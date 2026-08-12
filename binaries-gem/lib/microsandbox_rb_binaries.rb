# frozen_string_literal: true

# Companion gem that ships the prebuilt `msb` microVM runtime + `libkrunfw`
# firmware for one platform, so the `microsandbox-rb` SDK gem never has to
# download them at first use. Prototype for the two-gem split proposed in
# upstream issue #1305 (superradcompany/microsandbox).
#
# Two build variants share this file:
# - platform gem (e.g. arm64-darwin): `vendor/{bin,lib}` holds the binaries and
#   {msb_path}/{libkrunfw_path} return their absolute paths;
# - `ruby`-platform fallback gem: no `vendor/` directory ships, both paths
#   return nil. The fallback exists so `bundle install` resolves cleanly on
#   platforms without a prebuilt bundle (musl, Windows) instead of failing —
#   consumers treat nil as "tier absent" and fall through their resolver.
module MicrosandboxRbBinaries
  # Lockstep with the microsandbox-rb gem version (no dependency edge exists
  # between the two gems in either direction, so version drift can only be
  # caught at runtime — see RUNTIME_VERSION).
  VERSION = "0.12.0"

  # The upstream runtime release the vendored binaries were downloaded from.
  # Must match microsandbox-rb's Microsandbox::RUNTIME_VERSION; the SDK runs
  # `msb --version` against whatever its resolver picks and warns on mismatch.
  RUNTIME_VERSION = "v0.6.8"

  class << self
    # @return [String, nil] absolute path to the vendored `msb` binary, or nil
    #   on the ruby-platform fallback gem (no binaries shipped).
    def msb_path
      path = File.join(vendor_dir, "bin", "msb")
      File.file?(path) ? path : nil
    end

    # @return [String, nil] absolute path to the vendored libkrunfw shared
    #   library, or nil on the ruby-platform fallback gem. The filename is
    #   platform-specific (e.g. `libkrunfw.5.dylib` on macOS), so glob rather
    #   than hardcode it.
    def libkrunfw_path
      Dir[File.join(vendor_dir, "lib", "libkrunfw*")].find { |f| File.file?(f) }
    end

    private

    def vendor_dir
      File.expand_path("../vendor", __dir__)
    end
  end
end
