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

  describe "RUNTIME_VERSION" do
    it "is exposed via .runtime_version" do
      expect(Microsandbox.runtime_version).to eq(Microsandbox::RUNTIME_VERSION)
    end

    # Guards against the constant silently drifting from the pinned upstream
    # source — the exact failure mode (a stale "currently vX.Y.Z" note) that
    # motivated adding the constant.
    #
    # TEMPORARY (matches the rev pin in ext/microsandbox/Cargo.toml): while
    # upstream #1300 (digest verification) is unreleased, the deps are
    # rev-pinned to an approved fork backport of RUNTIME_VERSION. Exactly two
    # shapes pass — both deps tag-pinned to the official repo at
    # RUNTIME_VERSION, or both deps rev-pinned to APPROVED_BACKPORT — and
    # anything else (mixed pin kinds, mixed sources, an unapproved rev) fails.
    # On unpin, drop APPROVED_BACKPORT and the rev branch.
    official_repo = "https://github.com/superradcompany/microsandbox"
    approved_backport = {
      # ya-luotao/microsandbox branch `v0.6.8-digest-backport`: the `base`
      # runtime release + upstream #1300 digest verification + agentd
      # prebuilt digest verification. Update in lock-step with Cargo.toml.
      git: "https://github.com/ya-luotao/microsandbox",
      rev: "32b8b98ee4d61b27773404aa6b0d0978295a2edc",
      base: "v0.6.8"
    }

    it "stays in sync with the upstream pin in ext/microsandbox/Cargo.toml" do
      cargo = File.read(File.expand_path("../../ext/microsandbox/Cargo.toml", __dir__))
      deps = ["microsandbox", "microsandbox-network"].to_h do |name|
        decl = cargo[/^#{Regexp.escape(name)}\s*=\s*\{[^}]*\}/]
        expect(decl).not_to be_nil, "missing #{name} git dependency declaration"
        [name, {
          git: decl[/\bgit\s*=\s*"([^"]+)"/, 1],
          tag: decl[/\btag\s*=\s*"([^"]+)"/, 1],
          rev: decl[/\brev\s*=\s*"([^"]+)"/, 1]
        }]
      end

      gits = deps.values.map { |dep| dep[:git] }
      tags = deps.values.map { |dep| dep[:tag] }
      revs = deps.values.map { |dep| dep[:rev] }

      if tags.all?
        expect(revs).to all(be_nil), "mixed tag+rev pin: #{deps}"
        expect(gits.uniq).to eq([official_repo])
        expect(tags.uniq).to eq([Microsandbox::RUNTIME_VERSION])
      else
        expect(tags).to all(be_nil), "mixed tag/rev pin kinds: #{deps}"
        expect(gits.uniq).to eq([approved_backport[:git]])
        expect(revs.uniq).to eq([approved_backport[:rev]])
        # Bind the approval to the constant: the approved rev vouches for one
        # specific base release, so RUNTIME_VERSION cannot drift while the
        # rev pin is in place.
        expect(Microsandbox::RUNTIME_VERSION).to eq(approved_backport[:base])
      end
    end
  end
end
