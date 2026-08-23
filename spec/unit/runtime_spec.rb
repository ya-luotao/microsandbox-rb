# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Microsandbox runtime helpers" do
  # Set real process environment variables for the block (the native resolver
  # reads the process env, which a stub_const("ENV") cannot reach) and restore.
  def with_env(pairs)
    saved = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  describe ".installed?" do
    it "returns a boolean" do
      expect([true, false]).to include(Microsandbox.installed?)
    end
  end

  describe ".runtime_path" do
    # The gem is SDK-only (no build-time runtime download), so a clean host has
    # nothing for the resolver's lower tiers to find and the bare call raises.
    # `MSB_PATH` is the resolver's top tier and is returned as-is, which makes
    # the example deterministic without a runtime install. The Rust resolver
    # reads the real process environment, so set ENV itself (not a stub_const).
    it "returns the resolved msb path as a string (MSB_PATH wins the ladder)" do
      Dir.mktmpdir do |dir|
        msb = File.join(dir, "msb")
        File.write(msb, "")
        with_env("MSB_PATH" => msb) do
          expect(Microsandbox.runtime_path).to eq(msb)
        end
      end
    end
  end

  describe "bundled runtime (microsandbox-rb-binaries)" do
    # Fake companion gem: the module `require "microsandbox/binaries"` would
    # define, minus the files. stub_const scopes it to the example.
    def fake_binaries(runtime_version: Microsandbox::RUNTIME_VERSION, msb: "/gems/binaries/vendor/bin/msb",
      libkrunfw: "/gems/binaries/vendor/lib/libkrunfw.5.dylib")
      mod = Module.new
      mod.const_set(:VERSION, Microsandbox::VERSION)
      mod.const_set(:RUNTIME_VERSION, runtime_version)
      mod.define_singleton_method(:root) { "/gems/binaries/vendor" }
      mod.define_singleton_method(:msb_path) { msb }
      mod.define_singleton_method(:libkrunfw_path) { libkrunfw }
      mod
    end

    # `require` is Kernel#require on the Microsandbox module object (the
    # activation runs inside `class << self`), so it can be stubbed there.
    def stub_companion(mod)
      stub_const("Microsandbox::Binaries", mod) if mod
      allow(Microsandbox).to receive(:gem)
      allow(Microsandbox).to receive(:require).and_call_original
      if mod
        allow(Microsandbox).to receive(:require).with("microsandbox/binaries").and_return(true)
      else
        allow(Microsandbox).to receive(:require).with("microsandbox/binaries").and_raise(LoadError)
      end
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
      allow(Microsandbox).to receive(:warn)
    end

    def activate
      Microsandbox.send(:activate_bundled_runtime!)
    end

    around do |example|
      saved = Microsandbox.instance_variable_get(:@bundled_msb_path)
      example.run
      Microsandbox.instance_variable_set(:@bundled_msb_path, saved)
    end

    it "points the native resolver at the gem's msb when the runtime versions match" do
      stub_companion(fake_binaries)
      expect(activate).to eq("/gems/binaries/vendor/bin/msb")
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path).with("/gems/binaries/vendor/bin/msb")
      expect(Microsandbox).not_to have_received(:warn)
    end

    it "pins the companion gem to the lockstep version before requiring it" do
      stub_companion(fake_binaries)
      activate
      expect(Microsandbox).to have_received(:gem).with("microsandbox-rb-binaries", "= #{Microsandbox::VERSION}")
    end

    it "does nothing (silently) when the companion gem is not installed" do
      stub_companion(nil)
      expect(activate).to be_nil
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
      expect(Microsandbox).not_to have_received(:warn)
    end

    it "tolerates the companion gem being absent at the pinned version (Bundler raises Gem::LoadError)" do
      stub_companion(nil)
      allow(Microsandbox).to receive(:gem).and_raise(Gem::LoadError, "not in bundle")
      expect { activate }.not_to raise_error
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
    end

    it "warns and skips a companion gem built for a different upstream runtime" do
      # A stale msb passes an exists-check and then fails every create on a
      # wire-protocol mismatch — the regression that motivated version gating.
      stub_companion(fake_binaries(runtime_version: "v0.0.1"))
      expect(activate).to be_nil
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
      expect(Microsandbox).to have_received(:warn).with(a_string_matching(/ignoring microsandbox-rb-binaries .*v0\.0\.1/))
    end

    it "warns and skips a companion gem at a different gem version, even on the same runtime" do
      # Gem-only SDK releases share the runtime tag; the lockstep contract is
      # still "same version", and the `gem "= VERSION"` pin can't enforce it
      # (it raises under Bundler and is swallowed).
      mod = fake_binaries
      mod.send(:remove_const, :VERSION)
      mod.const_set(:VERSION, "0.0.1")
      stub_companion(mod)
      expect(activate).to be_nil
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
      expect(Microsandbox).to have_received(:warn).with(a_string_matching(/ignoring microsandbox-rb-binaries 0\.0\.1 .*same version/))
    end

    it "survives a companion gem whose binaries.rb does not even parse (SyntaxError is not a StandardError)" do
      stub_companion(nil)
      allow(Microsandbox).to receive(:require).with("microsandbox/binaries").and_raise(SyntaxError, "unexpected end-of-input")
      expect { activate }.not_to raise_error
      expect(activate).to be_nil
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
      expect(Microsandbox).to have_received(:warn).with(a_string_matching(/could not activate microsandbox-rb-binaries: SyntaxError/)).at_least(:once)
    end

    it "warns and skips a companion gem that carries no runtime" do
      stub_companion(fake_binaries(msb: nil))
      expect(activate).to be_nil
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
      expect(Microsandbox).to have_received(:warn).with(a_string_matching(/carries no runtime/))
    end

    it "requires the firmware beside msb, not just the binary" do
      stub_companion(fake_binaries(libkrunfw: nil))
      expect(activate).to be_nil
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
    end

    it "never raises out of activation (a broken companion must not break require)" do
      mod = fake_binaries
      mod.define_singleton_method(:msb_path) { raise IOError, "boom" }
      stub_companion(mod)
      expect { activate }.not_to raise_error
      expect(activate).to be_nil
      expect(Microsandbox).to have_received(:warn).with(a_string_matching(/could not activate microsandbox-rb-binaries: IOError: boom/)).at_least(:once)
    end

    it "refuses a microsandbox/binaries that a different gem provides" do
      stub_companion(fake_binaries)
      foreign = instance_double(Gem::Specification, name: "microsandbox-binaries", full_gem_path: File.dirname(__FILE__))
      allow(Gem).to receive(:loaded_specs).and_return({"microsandbox-binaries" => foreign})
      expect(activate).to be_nil
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
      expect(Microsandbox).to have_received(:warn).with(a_string_matching(/provided by the microsandbox-binaries gem/))
    end

    it "accepts this gem's own tree as the provider (source checkout under Bundler)" do
      stub_companion(fake_binaries)
      own = instance_double(Gem::Specification, name: "microsandbox-rb", full_gem_path: File.dirname(__FILE__))
      allow(Gem).to receive(:loaded_specs).and_return({"microsandbox-rb" => own})
      expect(activate).to eq("/gems/binaries/vendor/bin/msb")
    end

    it "accepts the companion gem itself as the provider" do
      stub_companion(fake_binaries)
      own = instance_double(Gem::Specification, name: "microsandbox-rb-binaries", full_gem_path: File.dirname(__FILE__))
      allow(Gem).to receive(:loaded_specs).and_return({"microsandbox-rb-binaries" => own})
      expect(activate).to eq("/gems/binaries/vendor/bin/msb")
    end

    it "is activated once at load time, so the slot is claimed before any entry point runs" do
      # Not every msb-spawning entry point goes through ensure_runtime!, so the
      # claim cannot be lazy. Assert the load-time hook exists rather than
      # re-requiring the gem (the native extension cannot be loaded twice).
      src = File.read(File.expand_path("../../lib/microsandbox.rb", __dir__))
      expect(src).to match(/^  send\(:activate_bundled_runtime!\)$/)
    end
  end

  describe ".runtime_path=" do
    it "forwards the stringified path to the native set-once setter" do
      # Stub the native setter so we (a) actually verify the binding forwards,
      # and (b) never consume the real process-wide set-once OnceLock — it has no
      # getter and cannot be restored, so writing a fake path here would leak
      # into the rest of the process (e.g. a combined unit+integration run with
      # :random order, where a later real-microVM example would then resolve the
      # bogus msb path and fail with an order-dependent boot error). The previous
      # around-hook "restore" was a silent no-op for exactly that reason.
      # Mirrors the .libkrunfw_path= spec below.
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
      Microsandbox.runtime_path = "/custom/path/to/msb"
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path)
        .with("/custom/path/to/msb")
    end
  end

  describe ".runtime_path= with the binaries gem active" do
    around do |example|
      saved = Microsandbox.instance_variable_get(:@bundled_msb_path)
      Microsandbox.instance_variable_set(:@bundled_msb_path, "/gems/binaries/vendor/bin/msb")
      example.run
      Microsandbox.instance_variable_set(:@bundled_msb_path, saved)
    end

    it "warns that the set-once slot is already claimed and points at MSB_PATH" do
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.runtime_path = "/custom/msb"
      expect(Microsandbox).to have_received(:warn).with(a_string_matching(/runtime_path= ignored.*set MSB_PATH/))
    end
  end

  describe ".libkrunfw_path=" do
    it "forwards the stringified path to the native set-once setter" do
      # Stub the native setter so we (a) actually verify the binding forwards,
      # and (b) never consume the real process-wide set-once OnceLock — it has no
      # getter and cannot be restored, so touching it would leak into a combined
      # unit+integration run. Asserting the assignment's value would be a Ruby
      # tautology (an assignment evaluates to its RHS regardless of the setter),
      # so assert the forwarded native call instead.
      allow(Microsandbox::Native).to receive(:set_runtime_libkrunfw_path)
      Microsandbox.libkrunfw_path = "/custom/path/to/libkrunfw.dylib"
      expect(Microsandbox::Native).to have_received(:set_runtime_libkrunfw_path)
        .with("/custom/path/to/libkrunfw.dylib")
    end
  end

  describe "Native module" do
    it "exposes the expected module functions" do
      %i[
        version install installed? set_runtime_msb_path set_runtime_libkrunfw_path
        resolved_msb_path set_default_backend push_default_backend pop_default_backend
        default_backend_kind
      ].each do |m|
        expect(Microsandbox::Native).to respond_to(m)
      end
    end
  end

  describe ".ensure_runtime!" do
    # The memoized "ready" flag would leak across examples (and from a real
    # source-built runtime on the dev box), so reset it around each one.
    around do |example|
      Microsandbox.instance_variable_set(:@runtime_ready, nil)
      example.run
      Microsandbox.instance_variable_set(:@runtime_ready, nil)
    end

    it "still runs the version-correcting installer when the runtime is present" do
      # Regression guard for the stale-runtime boot failure (issue #18):
      # `installed?` checks file *presence* only, so a stale msb left by an older
      # gem passes it. `install` is idempotent + version-correcting (cheap
      # `msb --version`, re-downloads only on mismatch), so ensure_runtime! must
      # delegate to it even when present rather than short-circuit. It must NOT
      # warn in this case (nothing is missing).
      allow(Microsandbox).to receive(:installed?).and_return(true)
      allow(Microsandbox).to receive(:install)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.ensure_runtime!
      Microsandbox.ensure_runtime! # second call is memoized, not re-checked
      expect(Microsandbox).to have_received(:install).once
      expect(Microsandbox).not_to have_received(:warn)
    end

    it "auto-installs once (with a notice) when the runtime is missing" do
      allow(Microsandbox).to receive(:installed?).and_return(false)
      allow(Microsandbox).to receive(:install)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.ensure_runtime!
      Microsandbox.ensure_runtime! # second call should be memoized, not re-install
      expect(Microsandbox).to have_received(:install).once
      expect(Microsandbox).to have_received(:warn).once
    end

    it "does not auto-install when MICROSANDBOX_NO_AUTO_INSTALL is set" do
      allow(Microsandbox).to receive(:installed?).and_return(false)
      allow(Microsandbox).to receive(:install)
      stub_const("ENV", ENV.to_h.merge("MICROSANDBOX_NO_AUTO_INSTALL" => "1"))
      Microsandbox.ensure_runtime!
      expect(Microsandbox).not_to have_received(:install)
    end

    it "treats MICROSANDBOX_NO_AUTO_INSTALL=0/false as 'not disabled'" do
      allow(Microsandbox).to receive(:installed?).and_return(false)
      allow(Microsandbox).to receive(:install)
      allow(Microsandbox).to receive(:warn)
      stub_const("ENV", ENV.to_h.merge("MICROSANDBOX_NO_AUTO_INSTALL" => "false"))
      Microsandbox.ensure_runtime!
      expect(Microsandbox).to have_received(:install)
    end

    it "skips the installer when the binaries gem's msb is what the resolver returns" do
      Microsandbox.instance_variable_set(:@bundled_msb_path, "/gems/binaries/vendor/bin/msb")
      allow(Microsandbox).to receive(:runtime_path).and_return("/gems/binaries/vendor/bin/msb")
      allow(Microsandbox).to receive(:installed?)
      allow(Microsandbox).to receive(:install)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.ensure_runtime!
      expect(Microsandbox).not_to have_received(:installed?)
      expect(Microsandbox).not_to have_received(:install)
      expect(Microsandbox).not_to have_received(:warn)
    ensure
      Microsandbox.instance_variable_set(:@bundled_msb_path, nil)
    end

    it "still runs the installer when something outranks the bundled msb (e.g. MSB_PATH)" do
      Microsandbox.instance_variable_set(:@bundled_msb_path, "/gems/binaries/vendor/bin/msb")
      allow(Microsandbox).to receive(:runtime_path).and_return("/opt/custom/msb")
      allow(Microsandbox).to receive(:installed?).and_return(true)
      allow(Microsandbox).to receive(:install)
      Microsandbox.ensure_runtime!
      expect(Microsandbox).to have_received(:install).once
    ensure
      Microsandbox.instance_variable_set(:@bundled_msb_path, nil)
    end

    it "treats a resolver error as 'bundled runtime not active' rather than raising" do
      Microsandbox.instance_variable_set(:@bundled_msb_path, "/gems/binaries/vendor/bin/msb")
      allow(Microsandbox).to receive(:runtime_path).and_raise(Microsandbox::Error, "msb binary not found")
      allow(Microsandbox).to receive(:installed?).and_return(true)
      allow(Microsandbox).to receive(:install)
      expect { Microsandbox.ensure_runtime! }.not_to raise_error
      expect(Microsandbox).to have_received(:install).once
    ensure
      Microsandbox.instance_variable_set(:@bundled_msb_path, nil)
    end

    it "skips the local-runtime check entirely under a cloud backend" do
      # A cloud backend has no local msb/libkrunfw to provision, so neither the
      # presence/version check nor a download should run.
      allow(Microsandbox).to receive(:default_backend_kind).and_return(:cloud)
      allow(Microsandbox).to receive(:installed?)
      allow(Microsandbox).to receive(:install)
      Microsandbox.ensure_runtime!
      expect(Microsandbox).not_to have_received(:installed?)
      expect(Microsandbox).not_to have_received(:install)
    end
  end
end
