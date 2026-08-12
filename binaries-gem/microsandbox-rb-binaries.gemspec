# frozen_string_literal: true

require_relative "lib/microsandbox_rb_binaries"

# One gemspec, two build variants (upstream #1305 prototype):
#
# - default: platform gem for the host this prototype targets (arm64-darwin).
#   Requires `rake vendor` to have staged the runtime binaries first — the
#   build fails closed rather than silently producing an empty platform gem.
# - MSB_BINARIES_PLATFORM=ruby: the empty ruby-platform fallback. No binaries,
#   no executables — a stub `msb` exe here would shadow a real msb on PATH via
#   bundler binstubs, so the fallback ships none and consumers get nil from
#   MicrosandboxRbBinaries.msb_path instead.
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

  fallback = ENV["MSB_BINARIES_PLATFORM"] == "ruby"
  vendored = Dir.glob("vendor/{bin,lib}/*", base: __dir__).select do |f|
    File.file?(File.join(__dir__, f))
  end
  if !fallback && vendored.empty?
    raise Gem::InvalidSpecificationException,
      "no vendored binaries found — run `rake vendor` before building the platform gem"
  end

  spec.platform = fallback ? Gem::Platform::RUBY : "arm64-darwin"
  spec.files = fallback ? base_files : base_files + vendored
  spec.bindir = "exe"
  spec.executables = fallback ? [] : ["msb"]
end
