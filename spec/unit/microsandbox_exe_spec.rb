# frozen_string_literal: true

require "open3"
require "tmpdir"

# The `microsandbox` CLI shim (exe/microsandbox): argv forwarding, the
# defensive leading-`--` strip, and shell-convention exit codes (127 = no
# runtime, 126 = runtime present but not executable, 1 = unrelated SDK error).
#
# These subprocess examples drive the shim script directly (`ruby
# exe/microsandbox`), which covers the shim's own contract. The RubyGems
# `gem exec` layer in front of it — including the finding that a `--` after
# the command name is eaten by RubyGems itself — cannot be exercised here
# without compiling the gem into a throwaway GEM_HOME, so that layer is
# asserted by the installed-gem demo (binaries-gem/demo/gem_exec_127.sh,
# scenario C pins the arg-drop).
RSpec.describe "microsandbox exe shim" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:exe) { File.join(root, "exe", "microsandbox") }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = dir
      example.run
    end
  end

  def argv_echo_msb
    path = File.join(@tmp, "echo-msb")
    File.write(path, "#!/bin/sh\necho \"ARGV: [$*]\"\n")
    File.chmod(0o755, path)
    path
  end

  def run_shim(*args, msb_path: nil, prelude: nil)
    env = {
      "MSB_PATH" => msb_path,
      "MSB_LIBKRUNFW_PATH" => nil,
      "MSB_HOME" => File.join(@tmp, "msbhome"),
      "MICROSANDBOX_NO_AUTO_INSTALL" => "1"
    }
    ruby_args = ["-I", File.join(root, "lib")]
    ruby_args += ["-r", prelude] if prelude
    Bundler.with_unbundled_env do
      Open3.capture3(env, RbConfig.ruby, *ruby_args, exe, *args, chdir: root)
    end
  end

  it "forwards arguments verbatim to the resolved msb" do
    stdout, stderr, status = run_shim("run", "alpine", msb_path: argv_echo_msb)
    expect(status).to be_success, stderr
    expect(stdout.chomp).to eq("ARGV: [run alpine]")
  end

  it "strips one literal leading -- (live for binstub/bundle-exec callers)" do
    stdout, stderr, status = run_shim("--", "run", "alpine", msb_path: argv_echo_msb)
    expect(status).to be_success, stderr
    expect(stdout.chomp).to eq("ARGV: [run alpine]")
  end

  it "does not strip a first argument that merely looks option-like" do
    stdout, stderr, status = run_shim("--version", msb_path: argv_echo_msb)
    expect(status).to be_success, stderr
    expect(stdout.chomp).to eq("ARGV: [--version]")
  end

  it "exits 127 with guidance when no runtime resolves anywhere" do
    _, stderr, status = run_shim("run", "alpine")
    expect(status.exitstatus).to eq(127)
    expect(stderr).to include("no msb runtime found")
  end

  it "exits 127 when the resolved path does not exist (ENOENT)" do
    _, stderr, status = run_shim("run", "alpine", msb_path: File.join(@tmp, "missing-msb"))
    expect(status.exitstatus).to eq(127)
    expect(stderr).to include("failed to run")
  end

  it "exits 126 when the runtime exists but is not executable (shell convention)" do
    path = File.join(@tmp, "locked-msb")
    File.write(path, "#!/bin/sh\necho nope\n")
    File.chmod(0o000, path)
    _, stderr, status = run_shim("run", "alpine", msb_path: path)
    expect(status.exitstatus).to eq(126)
    expect(stderr).to include("failed to run")
  end

  it "exits 1 (not 127) for an unrelated SDK error — config defects are not command-not-found" do
    # Environment-only injection of a non-missing SDK error proved unreliable
    # (a url-less MSB_BACKEND=cloud falls back to local; a malformed
    # config.json is tolerated), so inject it via a -r prelude that makes the
    # loaded SDK raise the way a real backend/config defect would.
    prelude = File.join(@tmp, "prelude.rb")
    File.write(prelude, <<~RUBY)
      require "microsandbox"
      def Microsandbox.ensure_runtime!
        raise Microsandbox::Error, "backend configuration exploded"
      end
    RUBY
    _, stderr, status = run_shim("run", "alpine", prelude: prelude)
    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("backend configuration exploded")
    expect(stderr).not_to include("no msb runtime found")
  end
end
