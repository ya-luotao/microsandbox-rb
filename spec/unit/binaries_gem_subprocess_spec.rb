# frozen_string_literal: true

require "open3"
require "tmpdir"

# Real-OnceLock coverage for the runtime-slot handshake. The native set-once
# slot cannot be reset in-process, so these examples each boot a fresh ruby
# with a hermetic stub of the binaries companion gem on the load path (no
# dependency on the gitignored vendor tree). Kept to the two interleavings the
# in-process specs cannot express; everything else lives in
# binaries_gem_spec.rb against stubs.
RSpec.describe "runtime slot ownership against the real native set-once slot" do
  let(:root) { File.expand_path("../..", __dir__) }

  around do |example|
    Dir.mktmpdir do |dir|
      @stub_dir = dir
      msb = File.join(dir, "fake-msb")
      expected = Microsandbox::RUNTIME_VERSION.delete_prefix("v")
      File.write(msb, "#!/bin/sh\necho 'msb #{expected}'\n")
      File.chmod(0o755, msb)
      firmware = File.join(dir, "libkrunfw.5.dylib")
      File.write(firmware, "stub firmware")
      File.write(File.join(dir, "microsandbox_rb_binaries.rb"), <<~RUBY)
        module MicrosandboxRbBinaries
          VERSION = #{Microsandbox::VERSION.inspect}
          RUNTIME_VERSION = #{Microsandbox::RUNTIME_VERSION.inspect}
          def self.msb_path = #{msb.inspect}
          def self.libkrunfw_path = #{firmware.inspect}
        end
      RUBY
      @stub_msb = msb
      example.run
    end
  end

  def run_ruby(script)
    env = {"MSB_PATH" => nil, "MICROSANDBOX_NO_AUTO_INSTALL" => nil}
    Bundler.with_unbundled_env do
      Open3.capture3(env, RbConfig.ruby,
        "-I", File.join(root, "lib"), "-I", @stub_dir,
        "-e", script, chdir: root)
    end
  end

  it "getter-then-setter: the gem claim holds, and the late setter warns instead of failing silently" do
    stdout, stderr, status = run_ruby(<<~RUBY)
      require "microsandbox"
      puts Microsandbox.runtime_path
      Microsandbox.runtime_path = "/opt/late/msb"
      puts Microsandbox.runtime_path
    RUBY
    expect(status).to be_success, "subprocess failed: #{stderr}"
    expect(stdout.lines.map(&:chomp)).to eq([@stub_msb, @stub_msb])
    expect(stderr).to include("runtime_path= ignored")
  end

  it "setter-first: a startup-time user override beats the gem tier, with no warning" do
    stdout, stderr, status = run_ruby(<<~RUBY)
      require "microsandbox"
      Microsandbox.runtime_path = "/opt/user/msb"
      puts Microsandbox.runtime_path
    RUBY
    expect(status).to be_success, "subprocess failed: #{stderr}"
    expect(stdout.chomp).to eq("/opt/user/msb")
    expect(stderr).not_to include("ignored")
  end
end
