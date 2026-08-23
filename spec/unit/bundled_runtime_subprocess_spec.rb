# frozen_string_literal: true

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
  # like a real `gem install`), with MSB_PATH scrubbed unless given.
  def run_child(include_dir, code, env = {})
    base = {"MSB_PATH" => nil, "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil,
            "MICROSANDBOX_NO_AUTO_INSTALL" => "1"}
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

  it "lets MSB_PATH outrank the companion gem" do
    Dir.mktmpdir do |dir|
      fake_companion(dir)
      out, err, status = run_child(dir, report, "MSB_PATH" => "/opt/custom/msb")
      expect(status).to be_success, err
      expect(out).to eq("/opt/custom/msb")
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
        Microsandbox.define_singleton_method(:install) { raise "install must not run" }
        Microsandbox.ensure_runtime!
        print Microsandbox.runtime_path
      RUBY
      out, err, status = run_child(dir, code, "MICROSANDBOX_NO_AUTO_INSTALL" => nil)
      expect(status).to be_success, err
      expect(out).to eq(msb)
    end
  end
end
