# frozen_string_literal: true

RSpec.describe Microsandbox do
  describe "VERSION" do
    it "is a semantic version string" do
      expect(Microsandbox::VERSION).to match(/\A\d+\.\d+\.\d+/)
    end
  end

  describe ".version" do
    it "returns the gem version" do
      expect(Microsandbox.version).to eq(Microsandbox::VERSION)
    end

    it "agrees with the native extension version" do
      expect(Microsandbox::Native.version).to eq(Microsandbox::VERSION)
    end
  end

  describe "RUNTIME_VERSION" do
    it "is exposed via .runtime_version" do
      expect(Microsandbox.runtime_version).to eq(Microsandbox::RUNTIME_VERSION)
    end

    # Guards against the constant silently drifting from the pinned git tag — the
    # exact failure mode (a stale "currently vX.Y.Z" note) that motivated adding
    # the constant. Also asserts both git deps share one tag.
    it "stays in sync with the upstream tag pinned in ext/microsandbox/Cargo.toml" do
      cargo = File.read(File.expand_path("../../ext/microsandbox/Cargo.toml", __dir__))
      tags = cargo.scan(/^microsandbox(?:-network)?\s*=\s*\{[^}]*\btag\s*=\s*"([^"]+)"/).flatten
      expect(tags).not_to be_empty
      expect(tags.uniq).to eq([Microsandbox::RUNTIME_VERSION])
    end
  end
end
