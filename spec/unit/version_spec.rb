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

    # The version lives in three committed places: version.rb (here), the ext
    # Cargo.toml [package] (covered indirectly by Native.version, which returns
    # CARGO_PKG_VERSION), and the root Cargo.lock. The gemspec packs Cargo.lock,
    # so a release that bumps version.rb + Cargo.toml but forgets to refresh the
    # lock would ship a stale lock — and a --locked/strict-downstream build would
    # reject it. Guard the lock copy too (mirrors the runtime-tag guard below).
    it "agrees with the microsandbox_rb version in the committed Cargo.lock" do
      lock = File.read(File.expand_path("../../Cargo.lock", __dir__))
      locked = lock[/^name = "microsandbox_rb"\n(?:.*\n)*?version = "([^"]+)"/, 1]
      expect(locked).to eq(Microsandbox::VERSION)
    end
  end

  # The companion binaries gem (binaries/) has no dependency edge to this gem,
  # so its version constants are the only lockstep guard: `VERSION` must track
  # this gem (released together, same number) and `RUNTIME_VERSION` must name
  # the same upstream runtime — the SDK refuses the gem's msb otherwise.
  describe "microsandbox-rb-binaries lockstep" do
    let(:binaries_dir) { File.expand_path("../../binaries", __dir__) }

    before { require File.join(binaries_dir, "lib/microsandbox/binaries") }

    it "keeps Microsandbox::Binaries::VERSION equal to the gem version" do
      expect(Microsandbox::Binaries::VERSION).to eq(Microsandbox::VERSION)
    end

    it "keeps Microsandbox::Binaries::RUNTIME_VERSION equal to the wrapped runtime" do
      expect(Microsandbox::Binaries::RUNTIME_VERSION).to eq(Microsandbox::RUNTIME_VERSION)
    end

    it "has a gemspec that evaluates without a vendored runtime and carries the lockstep version" do
      spec = Gem::Specification.load(File.join(binaries_dir, "microsandbox-rb-binaries.gemspec"))
      expect(spec).not_to be_nil
      expect(spec.name).to eq("microsandbox-rb-binaries")
      expect(spec.version.to_s).to eq(Microsandbox::VERSION)
      expect(spec.files).to include("lib/microsandbox/binaries.rb")
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
