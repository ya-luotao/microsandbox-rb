# frozen_string_literal: true

require "tmpdir"
require "digest"
require_relative "../../binaries-gem/lib/microsandbox_rb_binaries/vendor_tools"

# Fail-closed packaging pipeline behind the binaries gem's `rake vendor` and
# platform-gem build (#1305 prototype): a missing checksum entry, a digest
# mismatch, an interrupted stage, or an incomplete runtime set must all fail
# before anything reaches the live vendor tree or a built gem.
RSpec.describe MicrosandboxRbBinaries::VendorTools do
  let(:tools) { described_class }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = dir
      example.run
    end
  end

  def write_fake_msb(dir, version: "0.6.8", exit_code: 0)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "msb")
    File.write(path, "#!/bin/sh\necho 'msb #{version}'\nexit #{exit_code}\n")
    File.chmod(0o755, path)
    path
  end

  def write_firmware(dir, name: "libkrunfw.5.dylib")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), "not really a dylib")
  end

  # A complete, valid staged tree (fake runtime) the happy paths build on.
  def staged_tree(version: "0.6.8")
    staging = File.join(@tmp, "staging")
    write_fake_msb(File.join(staging, "bin"), version: version)
    write_firmware(File.join(staging, "lib"))
    staging
  end

  describe ".expected_sha256!" do
    it "returns the digest for the named asset" do
      text = "abc123  microsandbox-darwin-aarch64.tar.gz\ndef456  other.tar.gz\n"
      expect(tools.expected_sha256!(text, "microsandbox-darwin-aarch64.tar.gz")).to eq("abc123")
    end

    it "fails closed when the checksums document has no entry for the asset" do
      text = "def456  other.tar.gz\n"
      expect { tools.expected_sha256!(text, "microsandbox-darwin-aarch64.tar.gz") }
        .to raise_error(/no entry for microsandbox-darwin-aarch64\.tar\.gz/)
    end
  end

  describe ".verify_sha256!" do
    it "accepts matching bytes" do
      data = "hello"
      expect { tools.verify_sha256!(data, Digest::SHA256.hexdigest(data), "x") }
        .not_to raise_error
    end

    it "raises on a digest mismatch" do
      expect { tools.verify_sha256!("tampered", "0" * 64, "bundle") }
        .to raise_error(/sha256 mismatch for bundle/)
    end
  end

  describe ".validate_staged!" do
    it "accepts a complete tree whose msb reports the expected version" do
      expect { tools.validate_staged!(staged_tree, "v0.6.8") }.not_to raise_error
    end

    it "rejects a tree missing msb (interrupted stage)" do
      staging = File.join(@tmp, "staging")
      write_firmware(File.join(staging, "lib"))
      expect { tools.validate_staged!(staging, "v0.6.8") }
        .to raise_error(/missing bin\/msb/)
    end

    it "rejects a tree missing the libkrunfw firmware" do
      staging = File.join(@tmp, "staging")
      write_fake_msb(File.join(staging, "bin"))
      expect { tools.validate_staged!(staging, "v0.6.8") }
        .to raise_error(/missing lib\/libkrunfw/)
    end

    it "rejects a staged msb reporting the wrong version" do
      expect { tools.validate_staged!(staged_tree(version: "0.6.6"), "v0.6.8") }
        .to raise_error(/reports version "0\.6\.6", expected 0\.6\.8/)
    end
  end

  describe ".stage_bundle!" do
    it "refuses to reuse a leftover staging dir from a crashed run" do
      staging = File.join(@tmp, "staging")
      FileUtils.mkdir_p(staging)
      expect { tools.stage_bundle!(File.join(@tmp, "whatever.tar.gz"), staging) }
        .to raise_error(/staging dir already exists/)
    end
  end

  describe ".promote!" do
    it "leaves the previous vendor tree untouched until a validated stage replaces it atomically" do
      vendor = File.join(@tmp, "vendor")
      write_fake_msb(File.join(vendor, "bin"), version: "0.6.6")
      # A failed validation aborts before promote! — vendor keeps the old bytes.
      staging = File.join(@tmp, "staging")
      write_fake_msb(File.join(staging, "bin")) # no firmware → invalid
      expect { tools.validate_staged!(staging, "v0.6.8") }.to raise_error(/libkrunfw/)
      expect(IO.popen([File.join(vendor, "bin", "msb"), "--version"], &:read)).to include("0.6.6")
      # A valid stage swaps in wholesale and removes the old tree.
      write_firmware(File.join(staging, "lib"))
      write_fake_msb(File.join(staging, "bin"), version: "0.6.8")
      tools.validate_staged!(staging, "v0.6.8")
      tools.promote!(staging, vendor)
      expect(IO.popen([File.join(vendor, "bin", "msb"), "--version"], &:read)).to include("0.6.8")
      expect(File.exist?(staging)).to be(false)
      expect(Dir["#{vendor}.old-*"]).to be_empty
    end
  end

  describe ".verify_manifest!" do
    it "passes a freshly staged + manifested tree and returns its entries" do
      staging = staged_tree
      tools.write_manifest!(staging)
      expect(tools.verify_manifest!(staging)).to contain_exactly("bin/msb", "lib/libkrunfw.5.dylib")
    end

    it "fails when the manifest is missing entirely" do
      expect { tools.verify_manifest!(staged_tree) }
        .to raise_error(/manifest\.sha256 missing/)
    end

    it "fails when a vendored file was modified after staging" do
      staging = staged_tree
      tools.write_manifest!(staging)
      File.write(File.join(staging, "bin", "msb"), "#!/bin/sh\necho tampered\n")
      expect { tools.verify_manifest!(staging) }
        .to raise_error(/digest mismatch for bin\/msb/)
    end

    it "fails when the manifest lists no firmware (incomplete runtime must not ship)" do
      staging = File.join(@tmp, "staging")
      write_fake_msb(File.join(staging, "bin"))
      tools.write_manifest!(staging)
      expect { tools.verify_manifest!(staging) }
        .to raise_error(/lists no lib\/libkrunfw/)
    end

    it "fails when unlisted files appeared in the vendor tree" do
      staging = staged_tree
      tools.write_manifest!(staging)
      File.write(File.join(staging, "bin", "extra"), "surprise")
      expect { tools.verify_manifest!(staging) }
        .to raise_error(/not in the manifest: bin\/extra/)
    end
  end
end
