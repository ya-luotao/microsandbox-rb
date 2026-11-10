# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# The version-aware runtime bootstrap (Microsandbox.ensure_runtime! /
# .install), end to end against real runtimes and real microVMs. Every scenario
# runs in a child process (spec/support/bootstrap_probe.rb) with a runtime home
# of its own, because the home, MSB_PATH and the SDK path slots are captured
# once per process.
#
# Opt-in on top of MICROSANDBOX_INTEGRATION, because four scenarios download the
# ~25 MB runtime bundle from GitHub:
#
#   MICROSANDBOX_BOOTSTRAP_MATRIX=1 MICROSANDBOX_INTEGRATION=1 \
#   MICROSANDBOX_STALE_RUNTIME_DIR=<v0.6.18 bin/ + lib/> \
#   MICROSANDBOX_STALE07_RUNTIME_DIR=<v0.7.2 bin/ + lib/> \
#   bundle exec rspec spec/integration/runtime_bootstrap_spec.rb
#
# The (d), (e), (f) and (h) scenarios use the vendored runtime
# (`rake -C binaries 'vendor[<platform>]'`), and so does preparing the image:
# every scenario has a fresh home, and pulling the test image into each one
# trips the registry's rate limit, so the test image is pulled once, unpacked
# into a directory, and the scenarios boot that directory image. Only (a)
# boots the OCI image itself.
RSpec.describe "runtime bootstrap matrix" do
  def root_dir = File.expand_path("../..", __dir__)

  def probe_script = File.join(root_dir, "spec", "support", "bootstrap_probe.rb")

  def sdk = Microsandbox::RUNTIME_VERSION.delete_prefix("v")

  def firmware = RUBY_PLATFORM.include?("darwin") ? "libkrunfw.5.dylib" : "libkrunfw.so.5.6.1"

  def vendor_dir = File.join(root_dir, "binaries", "vendor")

  def vendor_msb = File.join(vendor_dir, "bin", "msb")

  # With MICROSANDBOX_INTEGRATION set, the skip names only the matrix's own
  # opt-in: CI's "integration examples actually ran" check treats a pending
  # message mentioning MICROSANDBOX_INTEGRATION as spec_helper's runtime gate.
  before do
    if !ENV["MICROSANDBOX_INTEGRATION"]
      skip "set MICROSANDBOX_INTEGRATION=1 and MICROSANDBOX_BOOTSTRAP_MATRIX=1"
    elsif !ENV["MICROSANDBOX_BOOTSTRAP_MATRIX"]
      skip "opt-in bootstrap matrix: set MICROSANDBOX_BOOTSTRAP_MATRIX=1 (downloads the runtime bundle)"
    end
  end

  # A fresh, private, short runtime home per scenario (the agent socket lives
  # under it). /tmp is sticky, so the home's ancestors pass the privacy check.
  before(:all) { @shared = Dir.mktmpdir("bs-img-", File.realpath("/tmp")) }
  after(:all) { FileUtils.rm_rf(@shared) if @shared }

  around do |example|
    Dir.mktmpdir("bs-", File.realpath("/tmp")) do |dir|
      @dir = dir
      @home = File.join(dir, "h")
      Dir.mkdir(@home, 0o700)
      example.run
    end
  end

  def stale_dir(var)
    dir = ENV[var]
    skip "set #{var} to a runtime directory (bin/msb + lib/)" unless dir && File.file?(File.join(dir, "bin", "msb"))
    dir
  end

  def require_vendored!
    skip "vendor the runtime first: rake -C binaries 'vendor[<platform>]'" unless File.file?(vendor_msb)
  end

  # Copy a runtime directory's pair into the home, as an install would.
  def seed_home(source)
    FileUtils.mkdir_p([File.join(@home, "bin"), File.join(@home, "lib")])
    FileUtils.cp(File.join(source, "bin", "msb"), File.join(@home, "bin", "msb"))
    FileUtils.cp(Dir[File.join(source, "lib", "libkrunfw*")], File.join(@home, "lib"))
  end

  def home_msb = File.join(@home, "bin", "msb")

  def sha256(path) = Digest::SHA256.file(path).hexdigest

  # Plain `ruby` outside Bundler, with no runtime source but the ones a
  # scenario adds: no MSB_PATH, no companion gem (unless RUBYLIB adds it).
  def probe(env: {}, attempts: [{}], image: nil, **config)
    image ||= test_rootfs
    gems = File.join(@dir, "gems")
    FileUtils.mkdir_p(gems)
    base = {"MSB_HOME" => @home, "MSB_PATH" => nil, "MSB_LIBKRUNFW_PATH" => nil, "RUBYOPT" => nil,
            "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil, "GEM_HOME" => gems,
            "GEM_PATH" => gems, "MICROSANDBOX_NO_AUTO_INSTALL" => nil}
    payload = JSON.generate({"image" => image, "attempts" => attempts}.merge(config.transform_keys(&:to_s)))
    out, err, status = Open3.capture3(base.merge(env), RbConfig.ruby, "-I", File.join(root_dir, "lib"), probe_script, payload)
    expect(status).to be_success, "bootstrap probe failed (#{status}):\n#{err}\n#{out}"
    [JSON.parse(out.lines.last), err]
  end

  def expect_booted(report)
    report["attempts"].each do |attempt|
      expect(attempt["outcome"]).to eq("created"), attempt.inspect
      expect(attempt["echo"]).to eq("ok\n")
    end
  end

  def expect_current(report, origin)
    expect(report["runtime"]).to include("origin" => origin, "version" => sdk)
  end

  it "(a) empty home: warns, installs, boots (from the OCI image)" do
    report, err = probe(image: default_test_image)
    expect(err).to include("not found; downloading runtime #{sdk}")
    expect_current(report, "home")
    expect_booted(report)
  end

  it "(b) stale 0.6.18 home: warns (no embedded version), force-upgrades, boots a networked sandbox" do
    seed_home(stale_dir("MICROSANDBOX_STALE_RUNTIME_DIR"))
    report, err = probe
    expect(err).to include("with no embedded version (pre-0.7 msb or a wrapper script)").and include("replacing it")
    expect_current(report, "home")
    expect_booted(report)
  end

  it "(b') stale 0.7.2 home: warns, force-upgrades, boots" do
    seed_home(stale_dir("MICROSANDBOX_STALE07_RUNTIME_DIR"))
    report, err = probe
    expect(err).to include("runtime 0.7.2 in").and include("replacing it")
    expect_current(report, "home")
    expect_booted(report)
  end

  {
    "(c) stale 0.6.18" => ["MICROSANDBOX_STALE_RUNTIME_DIR", "no embedded version (pre-0.7 msb or a wrapper script)"],
    "(c') stale 0.7.2" => ["MICROSANDBOX_STALE07_RUNTIME_DIR", "runtime 0.7.2 at"]
  }.each do |label, (var, wording)|
    it "#{label} home + NO_AUTO_INSTALL: warns, replaces nothing, every create is refused" do
      seed_home(stale_dir(var))
      before = sha256(home_msb)
      report, err = probe(env: {"MICROSANDBOX_NO_AUTO_INSTALL" => "1"}, stub_installers: true,
        attempts: [{}, {"network" => "none"}])
      expect(err).to include(wording).and include("every local sandbox start will be refused")
      expect(sha256(home_msb)).to eq(before)
      report["attempts"].each do |attempt|
        expect(attempt).to include("outcome" => "error")
        expect(attempt["message"]).to include("does not advertise protected sandbox state")
      end
    end
  end

  it "(c'') empty home + NO_AUTO_INSTALL, no other source: RuntimeNotInstalledError, nothing written" do
    report, err = probe(env: {"MICROSANDBOX_NO_AUTO_INSTALL" => "1"}, stub_installers: true)
    expect(report["attempts"].first).to include("outcome" => "error", "error_class" => "Microsandbox::RuntimeNotInstalledError")
    expect(err).not_to match(/download/i)
    entries = Dir.children(@home).sort
    # Only what the core itself creates before it resolves the runtime (the
    # catalog and its run directory); never the runtime pair's bin/ and lib/,
    # and not the sandboxes directory: the SDK's #2041 workaround runs only
    # once a runtime resolves. (From an OCI image the core would also pull it
    # into cache/ and create sandboxes/ itself before failing.)
    expect(entries - %w[cache db run]).to be_empty, "home now holds #{entries.inspect}"
    expect(Dir.glob("**/{msb,libkrunfw*}", base: @home)).to be_empty
  end

  {
    "(d) partial home (msb only)" => [],
    "(d') matching msb + an unrelated lib/libkrunfw.backup" => ["libkrunfw.backup"]
  }.each do |label, extra|
    it "#{label}: RuntimeIncompleteError with the exact files to delete" do
      require_vendored!
      FileUtils.mkdir_p([File.join(@home, "bin"), File.join(@home, "lib")])
      FileUtils.cp(vendor_msb, home_msb)
      extra.each { |name| File.write(File.join(@home, "lib", name), "") }
      report, = probe(stub_installers: true)
      attempt = report["attempts"].first
      expect(attempt).to include("outcome" => "error", "error_class" => "Microsandbox::RuntimeIncompleteError")
      expect(attempt["message"]).to include("delete #{home_msb} and #{File.join(@home, "lib", firmware)}")
    end
  end

  it "(e) MSB_PATH only: origin :environment, libkrunfw from ../lib, boots" do
    require_vendored!
    report, = probe(env: {"MSB_PATH" => vendor_msb, "MICROSANDBOX_NO_AUTO_INSTALL" => "1"}, stub_installers: true)
    expect_current(report, "environment")
    expect(File.realpath(report["runtime"]["libkrunfw_path"])).to eq(File.realpath(File.join(vendor_dir, "lib", firmware)))
    expect_booted(report)
    expect(Dir.exist?(File.join(@home, "bin"))).to be(false)
  end

  it "(f) bundled: origin :sdk_package, both paths in binaries/vendor, boots" do
    require_vendored!
    report, = probe(env: {"RUBYLIB" => File.join(root_dir, "binaries", "lib"), "MICROSANDBOX_NO_AUTO_INSTALL" => "1"},
      stub_installers: true)
    expect_current(report, "sdk_package")
    expect(report["runtime"]["msb_path"]).to eq(vendor_msb)
    expect(report["runtime"]["libkrunfw_path"]).to start_with(vendor_dir)
    expect_booted(report)
  end

  it "(g) stale home, Sandbox.list then Sandbox.create in one process: completes" do
    seed_home(stale_dir("MICROSANDBOX_STALE_RUNTIME_DIR"))
    report, = probe(list_first: true)
    expect(report["listed"]).to eq(0)
    expect_current(report, "home")
    expect_booted(report)
  end

  # superradcompany/microsandbox#2041: on a fresh home a directory-image create
  # failed with ENOENT (only the OCI path creates <home>/sandboxes); the SDK
  # creates it first. The rootfs is the test image, saved from a scratch home
  # and unpacked.
  it "(h) bundled, fresh home, directory image: the SDK creates <home>/sandboxes and boots" do
    require_vendored!
    rootfs = test_rootfs
    expect(Dir.exist?(File.join(@home, "sandboxes"))).to be(false)
    report, = probe(env: {"RUBYLIB" => File.join(root_dir, "binaries", "lib"), "MICROSANDBOX_NO_AUTO_INSTALL" => "1"},
      stub_installers: true, image: rootfs)
    expect_booted(report)
    expect(File.stat(File.join(@home, "sandboxes")).mode & 0o7777).to eq(0o777 & ~File.umask)
  end

  # The test image as a directory, prepared once per run: pulled in a scratch
  # home (bundled runtime), saved as a docker archive, layers unpacked.
  def test_rootfs
    rootfs = File.join(@shared, "rootfs")
    return rootfs if File.exist?(File.join(@shared, "rootfs.ok"))
    require_vendored!
    scratch = File.join(@shared, "s")
    FileUtils.rm_rf(scratch)
    Dir.mkdir(scratch, 0o700)
    archive = File.join(@shared, "image.tar")
    code = <<~RUBY
      require "microsandbox"
      Microsandbox::Sandbox.create("bs-seed", image: #{default_test_image.inspect}) { |sb| sb.exec("true") }
      Microsandbox::Sandbox.remove("bs-seed")
      Microsandbox::Image.save(#{default_test_image.inspect}, output_path: #{archive.inspect})
    RUBY
    env = {"MSB_HOME" => scratch, "MSB_PATH" => nil, "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil,
           "RUBYLIB" => File.join(root_dir, "binaries", "lib"), "MICROSANDBOX_NO_AUTO_INSTALL" => "1"}
    _out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(root_dir, "lib"), "-e", code)
    expect(status).to be_success, "saving the test image failed: #{err}"
    unpacked = File.join(@shared, "image")
    FileUtils.rm_rf([unpacked, rootfs])
    FileUtils.mkdir_p([unpacked, rootfs])
    system("tar", "-xf", archive, "-C", unpacked, exception: true)
    layers = JSON.parse(File.read(File.join(unpacked, "manifest.json"))).first.fetch("Layers")
    layers.each { |layer| system("tar", "-xf", File.join(unpacked, layer), "-C", rootfs, exception: true) }
    FileUtils.touch(File.join(@shared, "rootfs.ok"))
    rootfs
  end
end
