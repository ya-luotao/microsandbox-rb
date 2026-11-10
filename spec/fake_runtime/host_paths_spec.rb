# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require_relative "fake_runtime_helper"

# GHSA-mcw9-9rf6-p4rm: a relative host path must be anchored to the working
# directory of the process that CREATES the sandbox, and stored that way, so a
# later start from another directory cannot mount a different host directory.
#
# Real native calls against the fake runtime (no VM): the create succeeds, and
# `Sandbox.get(name).config` shows exactly what a restart would read. (Until
# 0.17.x this ran with no runtime at all, reading back the row a failed create
# left behind; since runtime v0.7 a failed create leaves no row.)
RSpec.describe "host paths are pinned at create time (fake runtime)", :fake_runtime do
  let(:name) { "rb-paths-#{SecureRandom.hex(4)}" }

  around do |example|
    # A real directory: since runtime v0.7 a bind path through a symlink (macOS
    # /var -> /private/var) is refused unless follow_root_symlinks is set.
    Dir.mktmpdir("msb-rb-paths-", File.realpath(Dir.tmpdir)) do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(%w[rootfs/bin data])
        File.write("data/seed.txt", "seed")
        File.symlink("data", "link")
        example.run
      end
    end
  end

  after do
    Microsandbox::Sandbox.remove(name)
  rescue Microsandbox::Error
    nil
  end

  # The persisted config of a sandbox created (and stopped) from here.
  def persisted(**opts)
    Microsandbox::Sandbox.create(name, **opts).stop
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

  # A vsock host socket is not pinned because it can never be stored relative:
  # the core refuses the route before the sandbox is persisted. (Anchoring it
  # here instead could also push a short relative path over the Unix socket
  # path limit.) If a future runtime starts accepting one, this fails and the
  # route needs pinning like the paths above.
  it "refuses a relative vsock host socket outright, for both socket types" do
    [{"./agent.sock" => 5000}, [{host_socket: "agent.sock", port: 5000, socket_type: :dgram}]].each do |vsock|
      expect { Microsandbox::Sandbox.create(name, image: here("rootfs"), vsock: vsock) }
        .to raise_error(Microsandbox::InvalidConfigError, /vsock host path must be absolute/)
      expect { Microsandbox::Sandbox.get(name) }.to raise_error(Microsandbox::SandboxNotFoundError)
    end
  end

  it "stores relative TLS certificate paths as absolute paths" do
    tls = persisted(
      image: here("rootfs"),
      tls: {upstream_ca_cert: "ca.pem", intercept_ca_cert: "./cert.pem", intercept_ca_key: "key.pem"}
    ).dig("network", "tls")
    expect(tls.fetch("upstream_ca_cert")).to eq([here("ca.pem")])
    expect(tls.fetch("intercept_ca")).to include("cert_path" => here("cert.pem"), "key_path" => here("key.pem"))
  end

  # Sandbox.restore (0.18.0, replacing 0.17's create(from_snapshot:)): a
  # relative snapshot path is anchored to this directory at call time. No such
  # snapshot exists, so the lookup error shows the path that was tried, and
  # nothing is created. A bare name that is a file here is read as a path too
  # (an archive), like the core does.
  it "anchors a relative Sandbox.restore snapshot path to the current directory" do
    ["./missing-snap", Pathname("missing-snap")].each do |snapshot|
      expect { Microsandbox::Sandbox.restore(snapshot, name: name) }
        .to raise_error(Microsandbox::SnapshotNotFoundError, /#{Regexp.escape(here("missing-snap"))}/)
      expect { Microsandbox::Sandbox.get(name) }.to raise_error(Microsandbox::SandboxNotFoundError)
    end
    File.write("saved.tar.zst", "not an archive")
    expect { Microsandbox::Sandbox.restore("saved.tar.zst", name: name) }
      .to raise_error(Microsandbox::Error, /archive/)
    expect { Microsandbox::Sandbox.get(name) }.to raise_error(Microsandbox::SandboxNotFoundError)
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
