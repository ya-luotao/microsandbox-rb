# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "Microsandbox runtime helpers" do
  # The SDK's record of the binaries gem's activation (activate_bundled_runtime!).
  def bundled_ivars = %i[@bundled_msb_path @bundled_libkrunfw_path @bundled_libkrunfw_claimed]

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
    # `MSB_PATH` is the resolver's top tier, which makes the example
    # deterministic without a runtime install. Two runtime-v0.7 rules shape it:
    # the local backend captures MSB_PATH once, when it is first built, so the
    # example runs in a child process; and the executable needs its libkrunfw
    # (here `<dir>/../lib/`), because the core resolves the two as one pair.
    it "returns the resolved msb path as a string (MSB_PATH wins the ladder)" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p([File.join(dir, "bin"), File.join(dir, "lib")])
        msb = File.join(dir, "bin", "msb")
        File.write(msb, "")
        firmware = RUBY_PLATFORM.include?("darwin") ? "libkrunfw.5.dylib" : "libkrunfw.so.5.6.1"
        File.write(File.join(dir, "lib", firmware), "")
        code = 'require "microsandbox"; print Microsandbox.runtime_path'
        out, err, status = Open3.capture3({"MSB_PATH" => msb, "RUBYOPT" => nil},
          RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", code)
        expect(status).to be_success, err
        expect(out).to eq(msb)
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
      allow(Microsandbox::Native).to receive(:set_runtime_libkrunfw_path)
      allow(Microsandbox).to receive(:warn)
    end

    def activate
      Microsandbox.send(:activate_bundled_runtime!)
    end

    around do |example|
      saved = bundled_ivars.to_h { |ivar| [ivar, Microsandbox.instance_variable_get(ivar)] }
      example.run
      saved.each { |ivar, value| Microsandbox.instance_variable_set(ivar, value) }
    end

    it "points the native resolver at the gem's msb and libkrunfw (msb first) when the runtime versions match" do
      stub_companion(fake_binaries)
      stub_const("ENV", ENV.to_h.except("MSB_PATH"))
      expect(activate).to eq("/gems/binaries/vendor/bin/msb")
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path).with("/gems/binaries/vendor/bin/msb").ordered
      expect(Microsandbox::Native).to have_received(:set_runtime_libkrunfw_path)
        .with("/gems/binaries/vendor/lib/libkrunfw.5.dylib").ordered
      expect(Microsandbox.instance_variable_get(:@bundled_libkrunfw_claimed)).to be(true)
      expect(Microsandbox).not_to have_received(:warn)
    end

    # The resolver prefers the library slot over the library next to an
    # MSB_PATH runtime, so claiming it would pair that runtime with the
    # bundled library. An empty MSB_PATH counts as set, as in the core.
    ["/opt/custom/bin/msb", ""].each do |value|
      it "leaves the libkrunfw slot alone when MSB_PATH is set (#{value.inspect})" do
        stub_companion(fake_binaries)
        stub_const("ENV", ENV.to_h.merge("MSB_PATH" => value))
        expect(activate).to eq("/gems/binaries/vendor/bin/msb")
        expect(Microsandbox::Native).to have_received(:set_runtime_msb_path).with("/gems/binaries/vendor/bin/msb")
        expect(Microsandbox::Native).not_to have_received(:set_runtime_libkrunfw_path)
        expect(Microsandbox.instance_variable_get(:@bundled_libkrunfw_claimed)).to be(false)
        expect(Microsandbox.instance_variable_get(:@bundled_libkrunfw_path)).to eq("/gems/binaries/vendor/lib/libkrunfw.5.dylib")
      end
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

    # A host project that is itself a gem, with its bundle under the project
    # directory, is a path prefix of the companion gem. Which spec comes first
    # in Gem.loaded_specs depends on the project's name.
    it "attributes the provider to the innermost gem root, whatever the spec order" do
      stub_companion(fake_binaries)
      inner = File.dirname(__FILE__)
      host = instance_double(Gem::Specification, name: "host-app", full_gem_path: File.dirname(inner))
      companion = instance_double(Gem::Specification, name: "microsandbox-rb-binaries", full_gem_path: inner)
      [{"host-app" => host, "microsandbox-rb-binaries" => companion},
        {"microsandbox-rb-binaries" => companion, "host-app" => host}].each do |specs|
        allow(Gem).to receive(:loaded_specs).and_return(specs)
        expect(activate).to eq("/gems/binaries/vendor/bin/msb")
      end
    end

    it "is activated once at load time, so the slot is claimed before any entry point runs" do
      # Not every msb-spawning entry point goes through ensure_runtime!, so the
      # claim cannot be lazy. Assert the load-time hook exists rather than
      # re-requiring the gem (the native extension cannot be loaded twice).
      src = File.read(File.expand_path("../../lib/microsandbox.rb", __dir__), encoding: "UTF-8")
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

    it "refuses nil and empty paths instead of writing an empty set-once slot" do
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
      allow(Microsandbox::Native).to receive(:set_runtime_libkrunfw_path)
      expect { Microsandbox.runtime_path = nil }.to raise_error(ArgumentError, /runtime_path= needs a non-empty path/)
      expect { Microsandbox.runtime_path = "" }.to raise_error(ArgumentError)
      expect { Microsandbox.libkrunfw_path = nil }.to raise_error(ArgumentError, /libkrunfw_path= needs a non-empty path/)
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
      expect(Microsandbox::Native).not_to have_received(:set_runtime_libkrunfw_path)
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

  describe ".libkrunfw_path= with the binaries gem active" do
    around do |example|
      saved = bundled_ivars.to_h { |ivar| [ivar, Microsandbox.instance_variable_get(ivar)] }
      Microsandbox.instance_variable_set(:@bundled_msb_path, "/gems/binaries/vendor/bin/msb")
      Microsandbox.instance_variable_set(:@bundled_libkrunfw_path, "/gems/binaries/vendor/lib/libkrunfw.5.dylib")
      example.run
      saved.each { |ivar, value| Microsandbox.instance_variable_set(ivar, value) }
    end

    it "warns that the set-once slot is already claimed when the gem claimed it" do
      Microsandbox.instance_variable_set(:@bundled_libkrunfw_claimed, true)
      allow(Microsandbox::Native).to receive(:set_runtime_libkrunfw_path)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.libkrunfw_path = "/custom/libkrunfw.5.dylib"
      expect(Microsandbox).to have_received(:warn).with(a_string_matching(/libkrunfw_path= ignored.*MSB_PATH/))
    end

    it "does not warn when the gem left the slot free (MSB_PATH was set at require time)" do
      Microsandbox.instance_variable_set(:@bundled_libkrunfw_claimed, false)
      allow(Microsandbox::Native).to receive(:set_runtime_libkrunfw_path)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.libkrunfw_path = "/custom/libkrunfw.5.dylib"
      expect(Microsandbox).not_to have_received(:warn)
      expect(Microsandbox::Native).to have_received(:set_runtime_libkrunfw_path).with("/custom/libkrunfw.5.dylib")
    end
  end

  describe "Native module" do
    it "exposes the expected module functions" do
      %i[
        version runtime_info msb_version runtime_home_pair install_runtime setup installed?
        set_runtime_msb_path set_runtime_libkrunfw_path resolved_msb_path set_default_backend
        push_default_backend pop_default_backend default_backend_kind
      ].each do |m|
        expect(Microsandbox::Native).to respond_to(m)
      end
    end
  end

  def sdk_runtime = Microsandbox::RUNTIME_VERSION.delete_prefix("v")

  def firmware = RUBY_PLATFORM.include?("darwin") ? "libkrunfw.5.dylib" : "libkrunfw.so.5.6.1"

  # A RuntimeInfo whose version is given instead of read from the file.
  def runtime_info(origin:, version: sdk_runtime, msb: "/rt/bin/msb", lib: "/rt/lib/#{firmware}")
    info = Microsandbox::RuntimeInfo.new("msb_path" => msb, "libkrunfw_path" => lib, "origin" => origin.to_s)
    allow(info).to receive(:version).and_return(version)
    info
  end

  describe Microsandbox::RuntimeInfo do
    it "reads the version lazily, once, and judges it against the SDK's runtime" do
      info = Microsandbox::RuntimeInfo.new("msb_path" => "/nowhere/msb", "libkrunfw_path" => "/nowhere/lib", "origin" => "home")
      allow(Microsandbox::Native).to receive(:msb_version).and_return(sdk_runtime)
      expect(info.origin).to eq(:home)
      expect(Microsandbox::Native).not_to have_received(:msb_version)
      expect(info.matches_sdk?).to be(true)
      expect(info.legacy?).to be(false)
      expect(info.version).to eq(sdk_runtime)
      expect(Microsandbox::Native).to have_received(:msb_version).with("/nowhere/msb").once
    end

    it "is legacy (and mismatched) without an embedded version" do
      info = Microsandbox::RuntimeInfo.new("msb_path" => "/old/msb", "libkrunfw_path" => "/old/lib", "origin" => "home")
      allow(Microsandbox::Native).to receive(:msb_version).and_return(nil)
      expect(info.legacy?).to be(true)
      expect(info.matches_sdk?).to be(false)
    end

    it "is not legacy, but mismatched, for another v0.7 release" do
      info = Microsandbox::RuntimeInfo.new("msb_path" => "/v072/msb", "libkrunfw_path" => "/v072/lib", "origin" => "home")
      allow(Microsandbox::Native).to receive(:msb_version).and_return("0.7.2")
      expect(info.legacy?).to be(false)
      expect(info.matches_sdk?).to be(false)
    end
  end

  describe "Native.msb_version" do
    it "returns nil for a wrapper script without reading further" do
      Dir.mktmpdir do |dir|
        script = File.join(dir, "msb")
        File.write(script, "#!/bin/sh\nexec /opt/msb \"$@\"\n")
        expect(Microsandbox::Native.msb_version(script)).to be_nil
      end
    end

    it "raises a Microsandbox::Error for a missing file" do
      expect { Microsandbox::Native.msb_version("/nonexistent/msb") }.to raise_error(Microsandbox::Error)
    end
  end

  describe "Native.runtime_home_pair" do
    it "names the exact pair upstream's resolver expects in the runtime home" do
      Dir.mktmpdir do |home|
        with_env("MSB_HOME" => home, "MSB_PATH" => "/elsewhere/bin/msb") do
          expect(Microsandbox::Native.runtime_home_pair)
            .to eq([File.join(home, "bin", "msb"), File.join(home, "lib", firmware)])
        end
      end
    end
  end

  describe ".runtime_info origin" do
    around do |example|
      saved = bundled_ivars.to_h { |ivar| [ivar, Microsandbox.instance_variable_get(ivar)] }
      Microsandbox.instance_variable_set(:@bundled_msb_path, "/gems/binaries/vendor/bin/msb")
      example.run
      saved.each { |ivar, value| Microsandbox.instance_variable_set(ivar, value) }
    end

    def native_info(origin, msb)
      {"msb_path" => msb, "libkrunfw_path" => "/x/lib/#{firmware}", "origin" => origin}
    end

    def origin_for(origin, msb, env)
      allow(Microsandbox::Native).to receive(:runtime_info).and_return(native_info(origin, msb))
      stub_const("ENV", ENV.to_h.except("MSB_PATH").merge(env))
      Microsandbox.runtime_info.origin
    end

    it "classifies a configuration pair selected by MSB_PATH as :environment (a relative MSB_PATH too)" do
      expect(origin_for("configuration", "/opt/rt/bin/msb", "MSB_PATH" => "/opt/rt/bin/msb")).to eq(:environment)
      relative = "binaries/vendor/bin/msb"
      expect(origin_for("configuration", relative, "MSB_PATH" => relative)).to eq(:environment)
      expect(origin_for("configuration", File.expand_path(relative), "MSB_PATH" => relative)).to eq(:environment)
    end

    it "classifies a configuration pair selected by the binaries gem's slot as :sdk_package" do
      expect(origin_for("configuration", "/gems/binaries/vendor/bin/msb", {})).to eq(:sdk_package)
    end

    it "prefers :environment when the path matches both (the environment outranks the slot)" do
      expect(origin_for("configuration", "/gems/binaries/vendor/bin/msb",
        "MSB_PATH" => "/gems/binaries/vendor/bin/msb")).to eq(:environment)
    end

    it "keeps :configuration for runtime_path= / configured paths" do
      expect(origin_for("configuration", "/srv/custom/msb", "MSB_PATH" => "/opt/other/msb")).to eq(:configuration)
    end

    it "passes every other origin through untouched (never produces or rewrites :home)" do
      expect(origin_for("home", "/gems/binaries/vendor/bin/msb", "MSB_PATH" => "/gems/binaries/vendor/bin/msb")).to eq(:home)
      expect(origin_for("sdk_package", "/x/msb", {})).to eq(:sdk_package)
      expect(origin_for("installed", "/x/msb", {})).to eq(:installed)
    end
  end

  describe ".install (home self-check)" do
    around do |example|
      Dir.mktmpdir do |home|
        @home = home
        @msb = File.join(home, "bin", "msb")
        @lib = File.join(home, "lib", firmware)
        FileUtils.mkdir_p([File.dirname(@msb), File.dirname(@lib)])
        example.run
      end
    end

    before do
      allow(Microsandbox::Native).to receive(:runtime_home_pair).and_return([@msb, @lib])
      allow(Microsandbox::Native).to receive(:install_runtime).and_return({})
    end

    def put(*paths) = paths.each { |path| File.write(path, "") }

    it "installs into an empty home" do
      Microsandbox.install
      expect(Microsandbox::Native).to have_received(:install_runtime).with({}).once
    end

    it "keeps a complete, current home (no download) unless forced" do
      put(@msb, @lib)
      allow(Microsandbox::Native).to receive(:msb_version).with(@msb).and_return(sdk_runtime)
      Microsandbox.install
      expect(Microsandbox::Native).not_to have_received(:install_runtime)
      Microsandbox.install(force: true)
      expect(Microsandbox::Native).to have_received(:install_runtime).with({"force" => true}).once
    end

    [nil, "0.7.2"].each do |stale|
      it "replaces a stale home (msb #{stale.inspect})" do
        put(@msb, @lib)
        allow(Microsandbox::Native).to receive(:msb_version).with(@msb).and_return(stale)
        Microsandbox.install
        expect(Microsandbox::Native).to have_received(:install_runtime).with({"force" => true}).once
      end
    end

    it "treats an unreadable home msb as stale" do
      put(@msb, @lib)
      allow(Microsandbox::Native).to receive(:msb_version).and_raise(Microsandbox::Error, "malformed")
      Microsandbox.install
      expect(Microsandbox::Native).to have_received(:install_runtime).with({"force" => true})
    end

    it "refuses a partial home with the exact files to delete (force or not)" do
      put(@msb)
      allow(Microsandbox::Native).to receive(:msb_version).and_return(sdk_runtime)
      [{}, {force: true}].each do |kwargs|
        expect { Microsandbox.install(**kwargs) }.to raise_error(Microsandbox::RuntimeIncompleteError) { |e|
          expect(e.message).to include("found #{@msb}", "but not #{@lib}", "delete #{@msb} and #{@lib}")
        }
      end
      expect(Microsandbox::Native).not_to have_received(:install_runtime)
    end

    it "does not take an unrelated libkrunfw.* file for the library (no glob)" do
      put(@msb, File.join(@home, "lib", "libkrunfw.backup"), File.join(@home, "lib", "libkrunfw.4.dylib"))
      allow(Microsandbox::Native).to receive(:msb_version).and_return(sdk_runtime)
      expect { Microsandbox.install }.to raise_error(Microsandbox::RuntimeIncompleteError, /delete #{Regexp.escape(@msb)}/)
      expect(Microsandbox::Native).not_to have_received(:install_runtime)
    end

    it "checks the home itself, whatever MSB_PATH selects" do
      Dir.mktmpdir do |other|
        FileUtils.mkdir_p([File.join(other, "bin"), File.join(other, "lib")])
        put(File.join(other, "bin", "msb"), File.join(other, "lib", firmware), @msb)
        allow(Microsandbox::Native).to receive(:msb_version).and_return(sdk_runtime)
        stub_const("ENV", ENV.to_h.merge("MSB_PATH" => File.join(other, "bin", "msb")))
        expect { Microsandbox.install }.to raise_error(Microsandbox::RuntimeIncompleteError)
        expect(Microsandbox::Native).not_to have_received(:install_runtime)
      end
    end
  end

  describe ".ensure_runtime!" do
    # The memoized "ready" flag would leak across examples (and from a real
    # source-built runtime on the dev box), so reset it around each one. The
    # bundled-runtime record is saved and restored rather than cleared: with
    # the companion gem active (the CI bundled lane) clearing it would leave
    # the rest of the suite believing no bundled runtime exists.
    around do |example|
      saved = bundled_ivars.to_h { |ivar| [ivar, Microsandbox.instance_variable_get(ivar)] }
      Microsandbox.instance_variable_set(:@runtime_ready, nil)
      Microsandbox.instance_variable_set(:@bundled_msb_path, nil)
      example.run
    ensure
      Microsandbox.instance_variable_set(:@runtime_ready, nil)
      saved.each { |ivar, value| Microsandbox.instance_variable_set(ivar, value) }
    end

    before do
      allow(Microsandbox).to receive(:bootstrap_install)
      allow(Microsandbox).to receive(:warn)
      allow(Microsandbox::Native).to receive(:install_backend_runtime)
      allow(Microsandbox::Native).to receive(:install_runtime)
      allow(Microsandbox::Native).to receive(:backend_runtime_home_pair).and_return(["/home/u/.microsandbox/bin/msb", "/home/u/.microsandbox/lib/#{firmware}"])
    end

    def with_auto_install(disabled)
      env = ENV.to_h.except("MICROSANDBOX_NO_AUTO_INSTALL", "MSB_PATH", "MSB_LIBKRUNFW_PATH")
      env["MICROSANDBOX_NO_AUTO_INSTALL"] = "1" if disabled
      stub_const("ENV", env)
    end

    def resolves(info) = allow(Microsandbox).to receive(:backend_runtime_info).and_return(info)

    def mismatch_warning = /every local sandbox start will be refused/

    context "with auto-install on" do
      before { with_auto_install(false) }

      it "does nothing for a current runtime, and memoizes" do
        resolves(runtime_info(origin: :home, msb: "/home/u/.microsandbox/bin/msb"))
        Microsandbox.ensure_runtime!
        Microsandbox.ensure_runtime!
        expect(Microsandbox).to have_received(:backend_runtime_info).once
        expect(Microsandbox).not_to have_received(:bootstrap_install)
        expect(Microsandbox).not_to have_received(:warn)
      end

      it "auto-installs once (with a notice) when nothing resolves" do
        allow(Microsandbox).to receive(:backend_runtime_info).and_raise(Microsandbox::RuntimeNotInstalledError, "expected …")
        Microsandbox.ensure_runtime!
        Microsandbox.ensure_runtime!
        expect(Microsandbox).to have_received(:bootstrap_install).with("/home/u/.microsandbox/bin/msb").once
        expect(Microsandbox).to have_received(:warn).with(/not found; downloading runtime #{Regexp.escape(sdk_runtime)}/).once
      end

      # Issue #18: a stale runtime left in the home must be replaced, not
      # launched (v0.7 refuses it at every start).
      [[nil, /with no embedded version \(pre-0\.7 msb or a wrapper script\)/], ["0.7.2", /0\.7\.2/]].each do |version, wording|
        it "force-reinstalls a stale home runtime (#{version.inspect})" do
          resolves(runtime_info(origin: :home, version: version, msb: "/home/u/.microsandbox/bin/msb"))
          Microsandbox.ensure_runtime!
          expect(Microsandbox).to have_received(:bootstrap_install).with("/home/u/.microsandbox/bin/msb", force: true).once
          expect(Microsandbox).to have_received(:warn).with(a_string_matching(wording).and(matching(/replacing it/)))
        end
      end

      # The bootstrap install goes to the home of the backend's captured
      # configuration (decided above), never through the ambient installer
      # that explicit Microsandbox.install uses.
      it "installs into the backend's captured home, not through the ambient installer" do
        allow(Microsandbox).to receive(:bootstrap_install).and_call_original
        resolves(runtime_info(origin: :home, version: "0.7.2", msb: "/home/u/.microsandbox/bin/msb"))
        Microsandbox.ensure_runtime!
        expect(Microsandbox::Native).to have_received(:install_backend_runtime)
          .with("/home/u/.microsandbox/bin/msb", {"force" => true}).once
        expect(Microsandbox::Native).not_to have_received(:install_runtime)
      end

      it "does not replace a :home pair that is not the home pair it would install into" do
        resolves(runtime_info(origin: :home, version: "0.7.2", msb: "/other/home/bin/msb"))
        Microsandbox.ensure_runtime!
        expect(Microsandbox).not_to have_received(:bootstrap_install)
        expect(Microsandbox).to have_received(:warn).with(mismatch_warning)
      end

      %i[environment configuration sdk_package].each do |origin|
        it "never touches a mismatched #{origin} runtime: warns once instead" do
          resolves(runtime_info(origin: origin, version: "0.7.2", msb: "/opt/rt/bin/msb"))
          Microsandbox.ensure_runtime!
          Microsandbox.ensure_runtime!
          expect(Microsandbox).not_to have_received(:bootstrap_install)
          expect(Microsandbox::Native).not_to have_received(:install_backend_runtime)
          expect(Microsandbox).to have_received(:warn)
            .with("[microsandbox] runtime 0.7.2 at /opt/rt/bin/msb ≠ SDK #{sdk_runtime}: every local sandbox start will be refused").once
        end
      end

      it "words the mismatch for a runtime with no embedded version" do
        resolves(runtime_info(origin: :environment, version: nil, msb: "/opt/old/msb"))
        Microsandbox.ensure_runtime!
        expect(Microsandbox).to have_received(:warn).with(
          "[microsandbox] runtime no embedded version (pre-0.7 msb or a wrapper script) at /opt/old/msb ≠ " \
          "SDK #{sdk_runtime}: every local sandbox start will be refused"
        )
      end

      it "raises a partial home with the files to delete" do
        Dir.mktmpdir do |home|
          msb = File.join(home, "bin", "msb")
          lib = File.join(home, "lib", firmware)
          FileUtils.mkdir_p(File.dirname(msb))
          File.write(msb, "")
          allow(Microsandbox::Native).to receive(:backend_runtime_home_pair).and_return([msb, lib])
          allow(Microsandbox::Native).to receive(:msb_version).and_return(sdk_runtime)
          allow(Microsandbox).to receive(:backend_runtime_info).and_raise(Microsandbox::RuntimeIncompleteError, "expected both #{msb} and #{lib}")
          expect { Microsandbox.ensure_runtime! }.to raise_error(Microsandbox::RuntimeIncompleteError, /delete #{Regexp.escape(msb)} and #{Regexp.escape(lib)}/)
          expect(Microsandbox).not_to have_received(:bootstrap_install)
          expect(Microsandbox.instance_variable_get(:@runtime_ready)).to be_nil
        end
      end

      it "explains MSB_PATH's pairing rule when MSB_PATH has no libkrunfw" do
        stub_const("ENV", ENV.to_h.merge("MSB_PATH" => "/opt/custom/msb"))
        allow(Microsandbox).to receive(:backend_runtime_info).and_raise(Microsandbox::RuntimeIncompleteError, "/opt/custom/msb has no matching libkrunfw")
        expect { Microsandbox.ensure_runtime! }.to raise_error(Microsandbox::RuntimeIncompleteError, /no matching libkrunfw — MSB_PATH needs libkrunfw beside it/)
      end

      it "treats MICROSANDBOX_NO_AUTO_INSTALL=0/false as 'not disabled'" do
        stub_const("ENV", ENV.to_h.merge("MICROSANDBOX_NO_AUTO_INSTALL" => "false"))
        allow(Microsandbox).to receive(:backend_runtime_info).and_raise(Microsandbox::RuntimeNotInstalledError, "none")
        Microsandbox.ensure_runtime!
        expect(Microsandbox).to have_received(:bootstrap_install)
      end
    end

    context "with MICROSANDBOX_NO_AUTO_INSTALL set (never writes)" do
      before { with_auto_install(true) }

      it "4a: nothing resolves — no install, no warning; the operation raises" do
        allow(Microsandbox).to receive(:backend_runtime_info).and_raise(Microsandbox::RuntimeNotInstalledError, "none")
        Microsandbox.ensure_runtime!
        expect(Microsandbox).not_to have_received(:bootstrap_install)
        expect(Microsandbox::Native).not_to have_received(:install_backend_runtime)
        expect(Microsandbox).not_to have_received(:warn)
      end

      it "4b: a current runtime — nothing to say" do
        resolves(runtime_info(origin: :environment))
        Microsandbox.ensure_runtime!
        expect(Microsandbox).not_to have_received(:warn)
        expect(Microsandbox).not_to have_received(:bootstrap_install)
      end

      [nil, "0.7.2"].each do |version|
        it "4c: a mismatched runtime (#{version.inspect}), even the home's — warns, never replaces" do
          resolves(runtime_info(origin: :home, version: version, msb: "/home/u/.microsandbox/bin/msb"))
          Microsandbox.ensure_runtime!
          expect(Microsandbox).to have_received(:warn).with(mismatch_warning).once
          expect(Microsandbox).not_to have_received(:bootstrap_install)
          expect(Microsandbox::Native).not_to have_received(:install_backend_runtime)
        end
      end

      it "a partial runtime — left for the operation to raise" do
        allow(Microsandbox).to receive(:backend_runtime_info).and_raise(Microsandbox::RuntimeIncompleteError, "partial")
        expect { Microsandbox.ensure_runtime! }.not_to raise_error
        expect(Microsandbox).not_to have_received(:bootstrap_install)
        expect(Microsandbox.instance_variable_get(:@runtime_ready)).to be(true)
      end
    end

    it "skips everything when the binaries gem's pair is what the resolver selects" do
      with_auto_install(false)
      Microsandbox.instance_variable_set(:@bundled_msb_path, "/gems/binaries/vendor/bin/msb")
      Microsandbox.instance_variable_set(:@bundled_libkrunfw_path, "/gems/binaries/vendor/lib/#{firmware}")
      allow(Microsandbox::Native).to receive(:backend_runtime_info).and_return(
        "msb_path" => "/gems/binaries/vendor/bin/msb", "libkrunfw_path" => "/gems/binaries/vendor/lib/#{firmware}",
        "origin" => "configuration"
      )
      allow(Microsandbox::Native).to receive(:msb_version)
      Microsandbox.ensure_runtime!
      expect(Microsandbox::Native).not_to have_received(:msb_version)
      expect(Microsandbox).not_to have_received(:bootstrap_install)
      expect(Microsandbox).not_to have_received(:warn)
    end

    it "checks the version when something outranks the bundled msb (MSB_PATH)" do
      stub_const("ENV", ENV.to_h.except("MICROSANDBOX_NO_AUTO_INSTALL").merge("MSB_PATH" => "/opt/custom/bin/msb"))
      Microsandbox.instance_variable_set(:@bundled_msb_path, "/gems/binaries/vendor/bin/msb")
      allow(Microsandbox::Native).to receive(:backend_runtime_info).and_return(
        "msb_path" => "/opt/custom/bin/msb", "libkrunfw_path" => "/opt/custom/lib/#{firmware}", "origin" => "configuration"
      )
      allow(Microsandbox::Native).to receive(:msb_version).with("/opt/custom/bin/msb").and_return("0.7.2")
      Microsandbox.ensure_runtime!
      expect(Microsandbox).to have_received(:warn).with(mismatch_warning)
      expect(Microsandbox).not_to have_received(:bootstrap_install)
    end

    it "is not fooled by the bundled msb paired with a foreign library" do
      with_auto_install(false)
      Microsandbox.instance_variable_set(:@bundled_msb_path, "/gems/binaries/vendor/bin/msb")
      Microsandbox.instance_variable_set(:@bundled_libkrunfw_path, "/gems/binaries/vendor/lib/#{firmware}")
      allow(Microsandbox::Native).to receive(:backend_runtime_info).and_return(
        "msb_path" => "/gems/binaries/vendor/bin/msb", "libkrunfw_path" => "/custom/#{firmware}", "origin" => "configuration"
      )
      allow(Microsandbox::Native).to receive(:msb_version).and_return(sdk_runtime)
      Microsandbox.ensure_runtime!
      expect(Microsandbox::Native).to have_received(:msb_version)
    end

    it "skips the local-runtime check entirely under a cloud backend" do
      allow(Microsandbox).to receive(:default_backend_kind).and_return(:cloud)
      allow(Microsandbox).to receive(:backend_runtime_info)
      Microsandbox.ensure_runtime!
      expect(Microsandbox).not_to have_received(:backend_runtime_info)
      expect(Microsandbox).not_to have_received(:bootstrap_install)
    end
  end
end
