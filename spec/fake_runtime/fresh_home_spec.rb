# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "fake_runtime_helper"

# Runtime v0.7.14 creates `<home>/sandboxes/<name>` with a non-recursive mkdir
# on the directory- and disk-image paths; only the OCI path creates
# `<home>/sandboxes` first (superradcompany/microsandbox#2041). On a home where
# no install ever ran (the runtime came from MSB_PATH or the binaries gem) a
# directory-image create failed with ENOENT. The SDK now creates the directory
# before every local create — but only once a runtime resolves, so a create
# that is about to fail with RuntimeNotInstalledError still writes nothing.
RSpec.describe "fake runtime: a fresh runtime home", :fake_runtime do
  let(:probe_script) { File.expand_path("../support/fake_runtime/launch_probe.rb", __dir__) }
  let(:lib_dir) { File.expand_path("../../lib", __dir__) }

  it "creates <home>/sandboxes (with the OCI path's mode) and boots a directory-image sandbox" do
    Dir.mktmpdir("msb-rb-", File.realpath("/tmp")) do |home|
      env = {"MSB_HOME" => home, "MSB_PATH" => nil, "MSB_LIBKRUNFW_PATH" => nil, "FAKE_RELAY_LOG" => nil,
             "FAKE_FRESH_HOME" => "1"}
      name = unique_sandbox_name("fr-fresh")
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib_dir, probe_script, home, "default", name, "{}")
      expect(status).to be_success, "launch probe failed: #{err}\n#{out}"
      report = JSON.parse(out.lines.last)
      expect(report["outcome"]).to eq("created"), report.inspect
      expect(report["echo"]).to eq("ok\n")
      # Upstream's OCI path uses a plain create_dir_all: 0777 less the umask.
      expect(report["sandboxes_mode"]).to eq(0o777 & ~File.umask)
    end
  end

  it "writes nothing when no runtime resolves (the create raises RuntimeNotInstalledError)" do
    Dir.mktmpdir("msb-rb-", File.realpath("/tmp")) do |dir|
      home = File.join(dir, "home")
      Dir.mkdir(home)
      rootfs = File.join(dir, "rootfs")
      Dir.mkdir(rootfs)
      gems = File.join(dir, "gems")
      Dir.mkdir(gems)
      code = <<~RUBY
        require "microsandbox"
        begin
          Microsandbox::Sandbox.create("fresh-none", image: #{rootfs.inspect})
          print "created"
        rescue Microsandbox::Error => e
          print e.class.name
        end
      RUBY
      # Outside Bundler, with no runtime anywhere: no MSB_PATH, no binaries gem.
      env = {"MSB_HOME" => home, "MSB_PATH" => nil, "MSB_LIBKRUNFW_PATH" => nil, "RUBYOPT" => nil,
             "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil, "GEM_HOME" => gems,
             "GEM_PATH" => gems, "MICROSANDBOX_NO_AUTO_INSTALL" => "1"}
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib_dir, "-e", code)
      expect(status).to be_success, err
      expect(out).to eq("Microsandbox::RuntimeNotInstalledError")
      expect(File.exist?(File.join(home, "sandboxes"))).to be(false)
    end
  end
end
