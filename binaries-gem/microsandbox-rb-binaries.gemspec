# frozen_string_literal: true

require_relative "lib/microsandbox_rb_binaries"

# One gemspec, two build variants (upstream #1305 prototype), selected by
# MSB_BINARIES_PLATFORM:
#
# - "arm64-darwin" (any non-"ruby" value): the platform gem. Requires `rake
#   vendor` to have staged + manifested the runtime binaries first — the build
#   fails closed (manifest revalidation) rather than shipping a stale, partial,
#   or tampered vendor tree. Built via `rake build:platform`.
# - unset / "ruby" (the DEFAULT): the empty ruby-platform fallback. No
#   binaries, no executables — a stub `msb` exe here would shadow a real msb
#   on PATH via bundler binstubs, so the fallback ships none and consumers get
#   nil from MicrosandboxRbBinaries.msb_path instead.
#
# The fallback must be the default: the parent repo's Gemfile uses `gemspec`,
# whose bundler path source globs `*/*.gemspec` and EVALS this file on every
# `bundle` invocation — a default that demands a vendor manifest would break
# every vendor-less checkout (fresh clones, CI). Platform builds opt in
# explicitly.
Gem::Specification.new do |spec|
  spec.name = "microsandbox-rb-binaries"
  spec.version = MicrosandboxRbBinaries::VERSION
  spec.authors = ["Luo Tao"]
  spec.email = ["luotao@farainc.org"]

  spec.summary = "Prebuilt msb runtime + libkrunfw for microsandbox-rb"
  spec.description = "Platform-specific prebuilt binaries (msb microVM runtime + libkrunfw " \
    "firmware, upstream #{MicrosandboxRbBinaries::RUNTIME_VERSION}) for the microsandbox-rb " \
    "gem. PROTOTYPE for upstream issue #1305 — not published to rubygems.org."
  spec.homepage = "https://github.com/ya-luotao/microsandbox-rb"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["allowed_push_host"] = "" # prototype: block accidental `gem push`

  base_files = ["lib/microsandbox_rb_binaries.rb", "README.md"]

  requested = ENV["MSB_BINARIES_PLATFORM"].to_s
  fallback = requested.empty? || requested == "ruby"
  vendored = []
  unless fallback
    # Fail-closed revalidation at build time: the vendor tree must match the
    # sha256 manifest `rake vendor` wrote when it staged + validated the
    # bundle, and must contain the complete runtime (msb + firmware). A stale,
    # partial, or tampered tree fails the build instead of shipping.
    require_relative "lib/microsandbox_rb_binaries/vendor_tools"
    vendor_dir = File.join(__dir__, "vendor")
    begin
      # The manifest binds the tree to the runtime release it was staged from,
      # so a stale vendor tree fails here after a RUNTIME_VERSION bump. (The
      # finished gem's payload is verified again after packaging — see
      # rake build:platform — closing the gemspec-to-packaging TOCTOU window.)
      entries = MicrosandboxRbBinaries::VendorTools.verify_manifest!(
        vendor_dir, expected_runtime_version: MicrosandboxRbBinaries::RUNTIME_VERSION
      )
    rescue => e
      raise Gem::InvalidSpecificationException, e.message
    end
    vendored = entries.map { |rel| "vendor/#{rel}" } +
      ["vendor/#{MicrosandboxRbBinaries::VendorTools::MANIFEST_NAME}"]
  end

  spec.platform = fallback ? Gem::Platform::RUBY : requested
  spec.files = fallback ? base_files : base_files + vendored
  spec.bindir = "exe"
  spec.executables = fallback ? [] : ["msb"]
end
