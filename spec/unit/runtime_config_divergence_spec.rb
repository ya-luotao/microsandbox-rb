# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# The local backend captures its runtime configuration once, when it is first
# built; `ensure_runtime!`'s readiness check and install read it afresh. When
# the two disagree (MSB_HOME or MSB_PATH changed in between), bootstrap must
# refuse rather than check or repair a runtime `create` will not launch. Each
# case runs in a child process: the backend is process-wide and cannot be
# reset in-process. The installer is replaced by a recorder; nothing is
# downloaded.
RSpec.describe "runtime bootstrap vs the local backend's captured configuration (subprocess)" do
  let(:lib_dir) { File.expand_path("../../lib", __dir__) }
  let(:firmware) { RUBY_PLATFORM.include?("darwin") ? "libkrunfw.5.dylib" : "libkrunfw.so.5.6.1" }

  # A complete pair whose msb is a script: no embedded version, i.e. stale.
  def stale_pair(root)
    FileUtils.mkdir_p([File.join(root, "bin"), File.join(root, "lib")])
    msb = File.join(root, "bin", "msb")
    File.write(msb, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, msb)
    File.write(File.join(root, "lib", firmware), "")
    msb
  end

  # Child prelude: record installer calls with the home they would write to,
  # silence warnings, build the backend under the starting environment, then
  # apply `after` to ENV.
  def child_code(before_bootstrap)
    <<~RUBY
      require "json"
      require "microsandbox"
      calls = []
      Microsandbox::Native.define_singleton_method(:install_runtime) do |opts|
        calls << [opts, Microsandbox::Native.runtime_home_pair.first]
        {}
      end
      Microsandbox.define_singleton_method(:warn) { |*| }
      Microsandbox.default_backend_kind
      JSON.parse(ARGV[0]).each { |k, v| ENV[k] = v }
      #{before_bootstrap}
      error = begin
        Microsandbox.ensure_runtime!
        nil
      rescue Microsandbox::Error => e
        [e.class.name, e.message]
      end
      print JSON.generate(error: error, calls: calls, ready: Microsandbox.instance_variable_get(:@runtime_ready))
    RUBY
  end

  def run_child(dir, env, after, before_bootstrap: "", include: nil)
    gems = File.join(dir, "empty-gem-home")
    FileUtils.mkdir_p(gems)
    base = {"MSB_PATH" => nil, "MSB_LIBKRUNFW_PATH" => nil, "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil,
            "BUNDLER_SETUP" => nil, "RUBYLIB" => nil, "MICROSANDBOX_NO_AUTO_INSTALL" => nil,
            "GEM_HOME" => gems, "GEM_PATH" => gems}
    includes = ["-I", lib_dir]
    includes += ["-I", include] if include
    out, err, status = Open3.capture3(base.merge(env), RbConfig.ruby, *includes, "-e",
      child_code(before_bootstrap), JSON.generate(after))
    expect(status).to be_success, err
    JSON.parse(out)
  end

  def divergence = /runtime configuration changed after this process's local backend was created/

  around do |example|
    Dir.mktmpdir("cfg") { |dir| @dir = File.realpath(dir) and example.run }
  end

  let(:home_a) { File.join(@dir, "a") }
  let(:home_b) { File.join(@dir, "b") }

  before do
    stale_pair(home_a)
    stale_pair(home_b)
  end

  it "replaces a stale home runtime in the backend's own home when nothing changed" do
    result = run_child(@dir, {"MSB_HOME" => home_a}, {})
    expect(result["error"]).to be_nil
    expect(result["calls"]).to eq([[{"force" => true}, File.join(home_a, "bin", "msb")]])
    expect(result["ready"]).to be(true)
  end

  it "refuses when MSB_HOME changed after the backend was built: no install, not ready" do
    result = run_child(@dir, {"MSB_HOME" => home_a}, {"MSB_HOME" => home_b})
    klass, message = result["error"]
    expect(klass).to eq("Microsandbox::InvalidConfigError")
    expect(message).to match(divergence)
    expect(message).to include(home_a, home_b, "Microsandbox.set_default_backend(:local)")
    expect(result["calls"]).to eq([])
    expect(result["ready"]).to be_nil
  end

  it "refuses when MSB_PATH changed after the backend was built" do
    custom = stale_pair(File.join(@dir, "custom"))
    result = run_child(@dir, {"MSB_HOME" => home_a}, {"MSB_PATH" => custom})
    klass, message = result["error"]
    expect(klass).to eq("Microsandbox::InvalidConfigError")
    expect(message).to match(divergence).and include(custom)
    expect(result["calls"]).to eq([])
    expect(result["ready"]).to be_nil
  end

  it "refuses with MICROSANDBOX_NO_AUTO_INSTALL too, before that branch memoizes" do
    result = run_child(@dir, {"MSB_HOME" => home_a, "MICROSANDBOX_NO_AUTO_INSTALL" => "1"}, {"MSB_HOME" => home_b})
    expect(result["error"]&.first).to eq("Microsandbox::InvalidConfigError")
    expect(result["ready"]).to be_nil
  end

  it "proceeds against the new configuration once the backend is rebuilt (the documented remedy)" do
    result = run_child(@dir, {"MSB_HOME" => home_a}, {"MSB_HOME" => home_b},
      before_bootstrap: "Microsandbox.set_default_backend(:local)")
    expect(result["error"]).to be_nil
    expect(result["calls"]).to eq([[{"force" => true}, File.join(home_b, "bin", "msb")]])
  end

  it "refuses before the binaries gem's early return" do
    vendor = File.join(@dir, "vendor")
    stale_pair(vendor)
    gem_lib = File.join(@dir, "companion", "microsandbox")
    FileUtils.mkdir_p(gem_lib)
    File.write(File.join(gem_lib, "binaries.rb"), <<~RUBY)
      module Microsandbox
        module Binaries
          VERSION = #{Microsandbox::VERSION.inspect}
          RUNTIME_VERSION = #{Microsandbox::RUNTIME_VERSION.inspect}
          def self.root = #{vendor.inspect}
          def self.msb_path = File.join(root, "bin", "msb")
          def self.libkrunfw_path = File.join(root, "lib", #{firmware.inspect})
        end
      end
    RUBY
    custom = stale_pair(File.join(@dir, "custom"))
    result = run_child(@dir, {"MSB_HOME" => home_a}, {"MSB_PATH" => custom}, include: File.join(@dir, "companion"))
    expect(result["error"]&.first).to eq("Microsandbox::InvalidConfigError")
    expect(result["ready"]).to be_nil
  end
end
