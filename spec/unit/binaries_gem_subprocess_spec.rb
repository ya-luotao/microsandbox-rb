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
      @stub_firmware = firmware
      example.run
    end
  end

  def run_ruby(script)
    Dir.mktmpdir do |empty_home|
      # MSB_HOME → empty dir: isolates the resolver's home tier from the dev
      # box's real ~/.microsandbox, so "the gem tier stood down" is observable
      # as NORESOLVE instead of accidentally resolving a host runtime.
      env = {"MSB_PATH" => nil, "MSB_LIBKRUNFW_PATH" => nil,
             "MICROSANDBOX_NO_AUTO_INSTALL" => "1", "MSB_HOME" => empty_home}
      Bundler.with_unbundled_env do
        return Open3.capture3(env, RbConfig.ruby,
          "-I", File.join(root, "lib"), "-I", @stub_dir,
          "-e", script, chdir: root)
      end
    end
  end

  it "getter-then-setter: the gem claim holds (msb AND firmware), and the late setter warns" do
    stdout, stderr, status = run_ruby(<<~RUBY)
      require "microsandbox"
      puts Microsandbox.runtime_path
      Microsandbox.runtime_path = "/opt/late/msb"
      puts Microsandbox.runtime_path
      puts Microsandbox::Native.resolved_libkrunfw_path
    RUBY
    expect(status).to be_success, "subprocess failed: #{stderr}"
    lines = stdout.lines.map(&:chomp)
    expect(lines[0, 2]).to eq([@stub_msb, @stub_msb])
    # The firmware winner is the companion gem's own, found by adjacency to
    # the claimed msb — same tier for both binaries, no mixing.
    expect(lines[2]).to eq(@stub_firmware)
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

  it "firmware-first: a user libkrunfw override stands the whole gem tier down (no mixed runtime)" do
    # The user's firmware outranks the adjacency probe, so claiming the msb
    # slot would assemble gem-msb + user-firmware. With the tier stood down
    # and the home tier isolated, NOTHING resolves — proving the gem claimed
    # neither slot rather than mixing.
    stdout, stderr, status = run_ruby(<<~RUBY)
      require "microsandbox"
      Microsandbox.libkrunfw_path = "/opt/user/libkrunfw.dylib"
      begin
        puts "msb: " + Microsandbox.runtime_path
      rescue => e
        puts "msb: NORESOLVE"
      end
    RUBY
    expect(status).to be_success, "subprocess failed: #{stderr}"
    expect(stdout.chomp).to eq("msb: NORESOLVE")
    expect(stdout).not_to include(@stub_msb)
  end
end
