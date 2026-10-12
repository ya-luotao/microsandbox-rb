# frozen_string_literal: true

require "securerandom"

# REAL native calls that need neither a microVM nor the msb runtime: the local
# backend's catalog, typed-error mapping, and the whole host-side Volume /
# VolumeFs surface. They run on every PR (no KVM), unlike spec/integration.
#
# Requires the hermetic unit environment: spec_helper points MSB_HOME at a
# throwaway directory unless MICROSANDBOX_INTEGRATION is set, in which case the
# home is the caller's real one and these examples are skipped.
RSpec.describe "native layer, offline (no VM, no runtime)" do
  before do
    skip "writes to MSB_HOME; runs only in the hermetic unit environment" if ENV["MICROSANDBOX_INTEGRATION"]
  end

  def unique(prefix) = "#{prefix}-#{SecureRandom.hex(4)}"

  describe "typed error mapping" do
    it "raises SandboxNotFoundError from get / remove / start of an unknown name" do
      name = unique("nope")
      expect { Microsandbox::Sandbox.get(name) }.to raise_error(Microsandbox::SandboxNotFoundError, /#{name}/)
      expect { Microsandbox::Sandbox.remove(name) }.to raise_error(Microsandbox::SandboxNotFoundError)
      allow(Microsandbox).to receive(:ensure_runtime!)
      expect { Microsandbox::Sandbox.start(name) }.to raise_error(Microsandbox::SandboxNotFoundError)
    end

    it "raises the image / snapshot / volume not-found subclasses" do
      expect { Microsandbox::Image.get(unique("img")) }.to raise_error(Microsandbox::ImageNotFoundError)
      expect { Microsandbox::Image.remove(unique("img")) }.to raise_error(Microsandbox::ImageNotFoundError)
      expect { Microsandbox::Snapshot.get(unique("snap")) }.to raise_error(Microsandbox::SnapshotNotFoundError)
      expect { Microsandbox::Volume.get(unique("vol")) }.to raise_error(Microsandbox::VolumeNotFoundError)
    end

    it "raises InvalidConfigError for an out-of-range page size, before any listing" do
      expect { Microsandbox::Sandbox.list_with(limit: 0) }.to raise_error(Microsandbox::InvalidConfigError, /between 1 and 100/)
      expect { Microsandbox::Sandbox.list_with(limit: 101) }.to raise_error(Microsandbox::InvalidConfigError)
    end

    it "raises an Operation-keyed UnsupportedError for the cloud-only default volume" do
      expect { Microsandbox::Volume.get_default }.to raise_error(Microsandbox::UnsupportedError) { |e|
        expect(e.operation).to eq("volume.get_default")
      }
    end
  end

  describe "catalog reads on an empty home" do
    it "returns empty pages / lists rather than raising" do
      page = Microsandbox::Sandbox.list
      expect(page).to be_a(Microsandbox::SandboxPage)
      expect(Microsandbox::Image.list).to be_an(Array)
      expect(Microsandbox::Snapshot.list).to be_an(Array)
      expect(Microsandbox.all_sandbox_metrics).to be_a(Hash)
    end
  end

  describe "Volume + VolumeFs (host-side, real filesystem)" do
    let(:name) { unique("rb-unit-vol") }
    let(:fs) { Microsandbox::Volume.fs(name) }

    before { Microsandbox::Volume.create(name, quota_mib: 5, labels: {suite: "unit"}) }

    after do
      Microsandbox::Volume.remove(name)
    rescue Microsandbox::Error
      nil
    end

    it "persists kind / quota / labels and rejects a duplicate name" do
      info = Microsandbox::Volume.get(name)
      expect(info.kind).to eq(:dir)
      expect(info.quota_mib).to eq(5)
      expect(info.labels).to eq("suite" => "unit")
      expect(Microsandbox::Volume.list.map(&:name)).to include(name)
      expect { Microsandbox::Volume.create(name) }.to raise_error(Microsandbox::VolumeAlreadyExistsError)
    end

    it "round-trips binary data and directory operations" do
      fs.mkdir("d")
      fs.write("d/a.bin", "\x00\xffhi".b)
      expect(fs.read("d/a.bin").bytes).to eq([0, 255, 104, 105])
      expect(fs.read("d/a.bin").encoding).to eq(Encoding::ASCII_8BIT)
      expect(fs.exists?("d/a.bin")).to be(true)
      expect(fs.list("d").map(&:name)).to eq(["a.bin"])
      expect(fs.stat("d/a.bin").size).to eq(4)
      fs.copy("d/a.bin", "d/b.bin")
      fs.rename("d/b.bin", "d/c.bin")
      expect(fs.list("d").map(&:name)).to contain_exactly("a.bin", "c.bin")
      fs.remove_file("d/c.bin")
      fs.remove_dir("d")
      expect(fs.exists?("d")).to be(false)
    end

    it "re-roots absolute paths inside the volume instead of touching the host path" do
      fs.write("/abs.txt", "inside")
      expect(fs.read_text("abs.txt")).to eq("inside")
      expect(fs.exists?("/etc/passwd")).to be(false)
    end

    # A volume path never needs a `..` segment, so both layers refuse one in
    # every operation, wherever it sits in the path.
    it "refuses a `..` segment in every operation" do
      fs.mkdir("d")
      fs.write("d/a.txt", "x")
      attempts = {
        read: -> { fs.read("d/../d/a.txt") },
        read_text: -> { fs.read_text("../a.txt") },
        write: -> { fs.write("d/../b.txt", "x") },
        list: -> { fs.list("d/..") },
        mkdir: -> { fs.mkdir("d/../e") },
        remove_file: -> { fs.remove_file("d/../d/a.txt") },
        remove_dir: -> { fs.remove_dir("d/../d") },
        exists?: -> { fs.exists?("d/../d") },
        copy_src: -> { fs.copy("d/../d/a.txt", "c.txt") },
        copy_dst: -> { fs.copy("d/a.txt", "d/../c.txt") },
        rename_src: -> { fs.rename("d/../d/a.txt", "c.txt") },
        rename_dst: -> { fs.rename("d/a.txt", "d/../c.txt") },
        stat: -> { fs.stat("d/..") }
      }
      attempts.each do |operation, attempt|
        expect(&attempt).to raise_error(Microsandbox::FilesystemError, /traversal/), "#{operation} accepted a `..` segment"
      end
      expect(fs.list("").map(&:name)).to eq(["d"])
      expect(fs.list("d").map(&:name)).to eq(["a.txt"])
    end

    it "enforces the same rule below the Ruby wrapper" do
      native = Microsandbox::Native::Volume.fs(name)
      expect { native.write("d/../b.txt", "x".b) }.to raise_error(Microsandbox::FilesystemError, /traversal/)
      expect { native.mkdir("d/../e") }.to raise_error(Microsandbox::FilesystemError, /traversal/)
      expect { native.rename("d/a.txt", "d/../b.txt") }.to raise_error(Microsandbox::FilesystemError, /traversal/)
    end

    it "still accepts names that merely contain dots" do
      fs.write("..hidden", "x")
      fs.write("a..b/c...txt", "y")
      expect(fs.read_text("..hidden")).to eq("x")
      expect(fs.read_text("a..b/c...txt")).to eq("y")
    end
  end
end
