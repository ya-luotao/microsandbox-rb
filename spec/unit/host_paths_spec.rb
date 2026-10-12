# frozen_string_literal: true

require "securerandom"
require "tmpdir"

# GHSA-mcw9-9rf6-p4rm: a relative host path must be anchored to the working
# directory of the process that CREATES the sandbox, and stored that way, so a
# later start from another directory cannot mount a different host directory.
#
# These are real native calls with no runtime installed: the local backend
# persists the sandbox row before it looks for `msb`, the create then fails,
# and `Sandbox.get(name).config` shows exactly what a restart would read.
RSpec.describe "host paths are pinned at create time (no VM, no runtime)" do
  let(:name) { "rb-unit-paths-#{SecureRandom.hex(4)}" }

  around do |example|
    Dir.mktmpdir("msb-rb-paths-") do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(%w[rootfs/bin data])
        File.write("data/seed.txt", "seed")
        File.symlink("data", "link")
        example.run
      end
    end
  end

  before do
    # spec_helper isolates MSB_HOME only outside integration runs.
    skip "writes to MSB_HOME; runs only in the hermetic unit environment" if ENV["MICROSANDBOX_INTEGRATION"]
    allow(Microsandbox).to receive(:ensure_runtime!)
  end

  after do
    Microsandbox::Sandbox.remove(name)
  rescue Microsandbox::Error
    nil
  end

  # The persisted config of a create that got as far as spawning the runtime.
  def persisted(**opts)
    expect { Microsandbox::Sandbox.create(name, **opts) }.to raise_error(Microsandbox::Error, /msb/)
    Microsandbox::Sandbox.get(name).config
  end

  def here(*parts) = File.join(Dir.pwd, *parts)

  it "stores relative bind-mount sources as absolute paths" do
    config = persisted(image: here("rootfs"), volumes: {"/a" => "./data", "/b" => {bind: "data", ro: true}})
    hosts = config.fetch("mounts").to_h { |mount| [mount.fetch("guest"), mount.fetch("host")] }
    expect(hosts).to eq("/a" => here("data"), "/b" => here("data"))
  end

  it "leaves an absolute source untouched" do
    config = persisted(image: here("rootfs"), volumes: {"/a" => here("data")})
    expect(config.fetch("mounts").first.fetch("host")).to eq(here("data"))
  end

  it "anchors without following symlinks" do
    config = persisted(image: here("rootfs"), volumes: {"/a" => {bind: "link", follow_root_symlinks: true}})
    expect(config.fetch("mounts").first.fetch("host")).to eq(here("link"))
  end

  it "stores a relative directory rootfs as an absolute path" do
    config = persisted(image: "./rootfs")
    expect(config.fetch("image")).to eq("Bind" => {"path" => here("rootfs"), "follow_root_symlinks" => false})
  end

  it "stores a relative disk-image rootfs as an absolute path, with or without fstype:" do
    File.write("root.raw", "x" * 4096)
    expect(persisted(image: "./root.raw").dig("image", "DiskImage", "path")).to eq(here("root.raw"))
    Microsandbox::Sandbox.remove(name)
    expect(persisted(image: "./root.raw", fstype: "ext4").dig("image", "DiskImage", "path")).to eq(here("root.raw"))
  end

  it "stores a relative disk-mount source as an absolute path" do
    File.write("data.raw", "x" * 4096)
    config = persisted(image: here("rootfs"), volumes: {"/d" => {disk: "./data.raw", fstype: "ext4"}})
    expect(config.fetch("mounts").first).to include("type" => "DiskImage", "host" => here("data.raw"))
  end

  it "resolves a path-form from_snapshot: against the creating directory, and leaves a name alone" do
    expect { Microsandbox::Sandbox.create(name, from_snapshot: "./snap") }
      .to raise_error(Microsandbox::SnapshotNotFoundError, /#{Regexp.escape(here("snap"))}/)
    expect { Microsandbox::Sandbox.create(name, from_snapshot: "~snap") }
      .to raise_error(Microsandbox::SnapshotNotFoundError, /#{Regexp.escape(here("~snap"))}/)
    expect { Microsandbox::Sandbox.create(name, from_snapshot: "snap") }
      .to raise_error(Microsandbox::SnapshotNotFoundError, /#{Regexp.escape(File.join(ENV.fetch("MSB_HOME"), "snapshots", "snap"))}/)
  end

  it "stores relative TLS certificate paths as absolute paths" do
    tls = persisted(
      image: here("rootfs"),
      tls: {upstream_ca_cert: "ca.pem", intercept_ca_cert: "./cert.pem", intercept_ca_key: "key.pem"}
    ).dig("network", "tls")
    expect(tls.fetch("upstream_ca_cert")).to eq([here("ca.pem")])
    expect(tls.fetch("intercept_ca")).to include("cert_path" => here("cert.pem"), "key_path" => here("key.pem"))
  end

  it "stores relative patch sources as absolute paths, and still applies them" do
    config = persisted(image: here("rootfs"), patches: [
      Microsandbox::Patch.copy_file("data/seed.txt", "/seed.txt"),
      Microsandbox::Patch.copy_dir("./data", "/copied")
    ])
    sources = config.fetch("patches").map { |patch| patch.values.first.fetch("src") }
    expect(sources).to eq([here("data", "seed.txt"), here("data")])
    expect(File.read(here("rootfs", "seed.txt"))).to eq("seed")
    expect(File.read(here("rootfs", "copied", "seed.txt"))).to eq("seed")
  end
end
