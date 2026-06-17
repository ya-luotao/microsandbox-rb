# frozen_string_literal: true

require_relative "lib/microsandbox/version"

Gem::Specification.new do |spec|
  spec.name = "microsandbox"
  spec.version = Microsandbox::VERSION
  spec.authors = ["Super Rad Company"]
  spec.email = ["development@superrad.company"]

  spec.summary = "Lightweight microVM sandboxes for Ruby — run AI agents and untrusted code with hardware-level isolation."
  spec.description = <<~DESC
    The microsandbox gem provides native bindings to the microsandbox runtime via
    a Rust extension (magnus). It spins up real microVMs (not containers) in under
    100ms, runs standard OCI (Docker) images, and gives you full control over
    command execution, the guest filesystem, networking, volumes, snapshots, SSH,
    and secrets — all from an idiomatic, synchronous Ruby API. No daemon, no server
    to connect to: the runtime is embedded directly in your process.
  DESC

  spec.homepage = "https://github.com/superradcompany/microsandbox"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.1.0"
  # Per-platform precompiled gems (built with rb-sys) require a recent RubyGems.
  spec.required_rubygems_version = ">= 3.3.11"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/superradcompany/microsandbox/tree/main/sdk"
  spec.metadata["documentation_uri"] = "https://docs.microsandbox.dev/sdk/overview"
  spec.metadata["changelog_uri"] = "https://github.com/superradcompany/microsandbox/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["cargo_crate_name"] = "microsandbox_rb"

  # Files shipped in the gem. The compiled artifact lands under lib/microsandbox/
  # for precompiled platform gems; ext/ ships for source builds.
  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rs,toml,rb}",
    "sig/**/*.rbs",
    "rust-toolchain.toml",
    "Cargo.toml",
    "Cargo.lock",
    "README.md",
    "CHANGELOG.md",
    "DESIGN.md",
    "LICENSE"
  ]
  spec.require_paths = ["lib"]

  # The native extension. rb-sys drives the Cargo build through extconf.rb.
  spec.extensions = ["ext/microsandbox/extconf.rb"]

  # rb_sys is required at install time to compile the Rust extension from source.
  spec.add_dependency "rb_sys", "~> 0.9.91"
end
