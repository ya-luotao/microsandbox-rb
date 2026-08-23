# frozen_string_literal: true

require_relative "lib/microsandbox/binaries"

# Platform gem carrying the prebuilt msb + libkrunfw runtime for ONE platform.
# Build it with the Rakefile in this directory (`rake vendor[<platform>]` then
# `rake build[<platform>]`), never with a bare `gem build`: the Rakefile verifies
# the vendored tree against the release's published sha256 digests and sets
# `spec.platform` — this gemspec itself is platform-neutral and evaluates cleanly
# on a checkout without `vendor/` (bundler evaluates nested gemspecs when the
# parent Gemfile uses `gemspec`).
Gem::Specification.new do |spec|
  spec.name = "microsandbox-rb-binaries"
  spec.version = Microsandbox::Binaries::VERSION
  spec.authors = ["ya-luotao"]
  spec.email = ["luotao@hey.com"]

  spec.summary = "Prebuilt msb microVM runtime + libkrunfw firmware for the microsandbox-rb gem."
  spec.description = <<~DESC
    Platform-specific prebuilt binaries — the `msb` microVM runtime and the
    `libkrunfw` firmware from upstream microsandbox release
    #{Microsandbox::Binaries::RUNTIME_VERSION} — for the microsandbox-rb SDK gem.
    Install it alongside microsandbox-rb (same version) and the SDK uses these
    binaries instead of downloading the runtime into ~/.microsandbox on first
    use. Every file is verified against the upstream release's published
    checksums.sha256 when the gem is built.
  DESC

  spec.homepage = "https://github.com/ya-luotao/microsandbox-rb"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.1.0"
  # `x86_64-linux-gnu`-style platforms (the binaries are glibc-linked) need a
  # RubyGems that distinguishes libc variants; older ones mis-match musl hosts.
  spec.required_rubygems_version = ">= 3.3.11"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ya-luotao/microsandbox-rb/tree/main/binaries"
  spec.metadata["changelog_uri"] = "https://github.com/ya-luotao/microsandbox-rb/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = ["lib/microsandbox/binaries.rb", "README.md", "LICENSE"] +
    Dir.chdir(__dir__) { Dir["vendor/**/*"].select { |f| File.file?(f) } }
  spec.require_paths = ["lib"]
end
