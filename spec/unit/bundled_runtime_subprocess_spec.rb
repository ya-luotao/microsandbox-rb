# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# End-to-end check of the companion-gem tier against the REAL native set-once
# slot, in a child process (the slot cannot be reset in-process, and the
# in-process specs stub the native setter for exactly that reason). A fake
# `microsandbox-rb-binaries` is put on the load path; the child then requires
# the SDK and reports what the core resolver returns.
RSpec.describe "bundled runtime activation (subprocess)" do
  let(:lib_dir) { File.expand_path("../../lib", __dir__) }
  # Child-side probe: print the resolved msb path, or the resolver's error.
  let(:report) do
    'require "microsandbox"; begin; print Microsandbox.runtime_path; ' \
      'rescue Microsandbox::Error => e; print "ERROR: " + e.message; end'
  end

  def fake_companion(dir, runtime_version: Microsandbox::RUNTIME_VERSION)
    vendor = File.join(dir, "vendor")
    FileUtils.mkdir_p(File.join(vendor, "bin"))
    FileUtils.mkdir_p(File.join(vendor, "lib"))
    File.write(File.join(vendor, "bin", "msb"), "#!/bin/sh\necho msb 0.0.0\n")
    File.chmod(0o755, File.join(vendor, "bin", "msb"))
    File.write(File.join(vendor, "lib", "libkrunfw.5.dylib"), "")
    lib = File.join(dir, "lib", "microsandbox")
    FileUtils.mkdir_p(lib)
    File.write(File.join(lib, "binaries.rb"), <<~RUBY)
      module Microsandbox
        module Binaries
          VERSION = #{Microsandbox::VERSION.inspect}
          RUNTIME_VERSION = #{runtime_version.inspect}
          ROOT = #{vendor.inspect}
          def self.root = ROOT
          def self.msb_path = File.join(ROOT, "bin", "msb")
          def self.libkrunfw_path = File.join(ROOT, "lib", "libkrunfw.5.dylib")
        end
      end
    RUBY
    File.join(vendor, "bin", "msb")
  end

  # Plain `ruby` outside Bundler (so `-I` is the only way the fake gem is found,
  # like a real `gem install`), with MSB_PATH scrubbed unless given. GEM_HOME /
  # GEM_PATH point at an empty directory so a real `microsandbox-rb-binaries`
  # installed on the host cannot be activated instead of the fake one.
  def run_child(include_dir, code, env = {})
    gems = File.join(include_dir, "empty-gem-home")
    FileUtils.mkdir_p(gems)
    base = {"MSB_PATH" => nil, "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil,
            "MICROSANDBOX_NO_AUTO_INSTALL" => "1", "GEM_HOME" => gems, "GEM_PATH" => gems}
    Open3.capture3(base.merge(env), RbConfig.ruby, "-I", lib_dir, "-I", File.join(include_dir, "lib"), "-e", code)
  end

  it "makes the companion gem's msb the resolved runtime path" do
    Dir.mktmpdir do |dir|
      msb = fake_companion(dir)
      out, err, status = run_child(dir, report)
      expect(status).to be_success, err
      expect(out).to eq(msb)
      expect(err).not_to match(/microsandbox-rb-binaries/)
    end
  end

  # Since runtime v0.7 the core resolves msb and libkrunfw as ONE pair: an
  # MSB_PATH executable needs its library beside it (`<dir>/` or `<dir>/../lib/`)
  # or MSB_LIBKRUNFW_PATH.
  def custom_pair(dir)
    root = File.join(dir, "custom")
    FileUtils.mkdir_p([File.join(root, "bin"), File.join(root, "lib")])
    msb = File.join(root, "bin", "msb")
    File.write(msb, "#!/bin/sh\necho msb 0.0.0\n")
    File.chmod(0o755, msb)
    firmware = RUBY_PLATFORM.include?("darwin") ? "libkrunfw.5.dylib" : "libkrunfw.so.5.6.1"
    File.write(File.join(root, "lib", firmware), "")
    msb
  end

  it "lets MSB_PATH outrank the companion gem" do
    Dir.mktmpdir do |dir|
      fake_companion(dir)
      msb = custom_pair(dir)
      out, err, status = run_child(dir, report, "MSB_PATH" => msb)
      expect(status).to be_success, err
      expect(out).to eq(msb)
    end
  end

  it "refuses an MSB_PATH executable with no libkrunfw to pair it with (runtime v0.7)" do
    Dir.mktmpdir do |dir|
      fake_companion(dir)
      classed = 'require "microsandbox"; begin; print Microsandbox.runtime_path; ' \
        'rescue Microsandbox::Error => e; print "ERROR " + e.class.name + " " + e.code + ": " + e.message; end'
      out, err, status = run_child(dir, classed, "MSB_PATH" => "/opt/custom/msb")
      expect(status).to be_success, err
      expect(out).to start_with("ERROR Microsandbox::RuntimeIncompleteError runtime-incomplete: ")
        .and include("/opt/custom/msb has no matching libkrunfw")
    end
  end

  # Child-side probe: the resolved pair and its (gem-classified) origin.
  let(:info_report) do
    'require "microsandbox"; require "json"; i = Microsandbox.runtime_info; ' \
      "print JSON.generate([i.origin, i.msb_path, i.libkrunfw_path])"
  end

  it "claims both SDK slots: the pair is the companion's, origin :sdk_package" do
    Dir.mktmpdir do |dir|
      msb = fake_companion(dir)
      out, err, status = run_child(dir, info_report)
      expect(status).to be_success, err
      expect(JSON.parse(out)).to eq(["sdk_package", msb, File.join(dir, "vendor", "lib", "libkrunfw.5.dylib")])
    end
  end

  # The resolver prefers the library slot over the library next to an
  # MSB_PATH runtime, so with MSB_PATH set the companion leaves that slot free.
  it "pairs an MSB_PATH runtime with its own library, not the companion's (origin :environment)" do
    Dir.mktmpdir do |dir|
      fake_companion(dir)
      msb = custom_pair(dir)
      out, err, status = run_child(dir, info_report, "MSB_PATH" => msb)
      expect(status).to be_success, err
      origin, resolved_msb, lib = JSON.parse(out)
      expect([origin, resolved_msb]).to eq(["environment", msb])
      expect(File.realpath(lib)).to eq(File.realpath(Dir[File.join(dir, "custom", "lib", "libkrunfw*")].first))
    end
  end

  it "classifies a relative MSB_PATH as :environment" do
    Dir.mktmpdir do |dir|
      custom_pair(dir)
      gems = File.join(dir, "empty-gem-home")
      FileUtils.mkdir_p(gems)
      env = {"MSB_PATH" => "custom/bin/msb", "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil,
             "MICROSANDBOX_NO_AUTO_INSTALL" => "1", "GEM_HOME" => gems, "GEM_PATH" => gems}
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib_dir, "-e", info_report, chdir: dir)
      expect(status).to be_success, err
      origin, msb = JSON.parse(out)
      expect(origin).to eq("environment")
      # The core anchors it against the working directory.
      expect(File.realpath(msb)).to eq(File.realpath(File.join(dir, "custom", "bin", "msb")))
    end
  end

  it "refuses a companion gem built for another runtime and says so" do
    Dir.mktmpdir do |dir|
      msb = fake_companion(dir, runtime_version: "v0.0.1")
      out, err, status = run_child(dir, report)
      expect(status).to be_success, err
      expect(err).to include("ignoring microsandbox-rb-binaries #{Microsandbox::VERSION} (runtime v0.0.1)")
      expect(out).not_to eq(msb)
    end
  end

  it "skips auto-provisioning when the companion gem supplies the runtime" do
    Dir.mktmpdir do |dir|
      msb = fake_companion(dir)
      code = <<~RUBY
        require "microsandbox"
        Microsandbox.define_singleton_method(:install) { |**| raise "install must not run" }
        Microsandbox::Native.define_singleton_method(:install_runtime) { |*| raise "install_runtime must not run" }
        Microsandbox.define_singleton_method(:warn) { |*args| raise "unexpected warning: \#{args.inspect}" }
        Microsandbox.ensure_runtime!
        print Microsandbox.runtime_path
      RUBY
      out, err, status = run_child(dir, code, "MICROSANDBOX_NO_AUTO_INSTALL" => nil)
      expect(status).to be_success, err
      expect(out).to eq(msb)
    end
  end
end
