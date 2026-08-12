# frozen_string_literal: true

require "tmpdir"
require "digest"
require "rubygems/package"
require_relative "../../binaries-gem/lib/microsandbox_rb_binaries/vendor_tools"

# Fail-closed packaging pipeline behind the binaries gem's `rake vendor` and
# platform-gem build (#1305 prototype): a missing checksum entry, a digest
# mismatch, an interrupted stage or promotion, an incomplete or version-stale
# runtime set, and post-verification tampering must all fail before anything
# reaches the live vendor tree or ships inside a built gem.
RSpec.describe MicrosandboxRbBinaries::VendorTools do
  let(:tools) { described_class }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = dir
      example.run
    end
  end

  def write_fake_msb(dir, version: "0.6.8", exit_code: 0, sleep_first: nil)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "msb")
    body = +"#!/bin/sh\n"
    body << "sleep #{sleep_first}\n" if sleep_first
    body << "echo 'msb #{version}'\nexit #{exit_code}\n"
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end

  def write_firmware(dir, name: "libkrunfw.5.dylib")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), "not really a dylib")
  end

  # A complete, valid staged tree (fake runtime) the happy paths build on.
  def staged_tree(version: "0.6.8", exit_code: 0)
    staging = File.join(@tmp, "staging")
    write_fake_msb(File.join(staging, "bin"), version: version, exit_code: exit_code)
    write_firmware(File.join(staging, "lib"))
    staging
  end

  def manifest!(dir, runtime_version: "v0.6.8", bundle_sha256: "ab" * 32)
    tools.write_manifest!(dir, runtime_version: runtime_version, bundle_sha256: bundle_sha256)
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
    it "accepts a complete tree whose msb reports the expected version and exits 0" do
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

    it "rejects valid-looking output from a staged msb that exits nonzero" do
      expect { tools.validate_staged!(staged_tree(exit_code: 9), "v0.6.8") }
        .to raise_error(/exited 9/)
    end

    it "kills and rejects a staged msb that hangs instead of blocking the vendor task" do
      staging = File.join(@tmp, "staging")
      write_fake_msb(File.join(staging, "bin"), sleep_first: 5)
      write_firmware(File.join(staging, "lib"))
      expect { tools.validate_staged!(staging, "v0.6.8", timeout: 0.2) }
        .to raise_error(/did not finish/)
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

  describe ".promote! / .recover_orphans!" do
    it "leaves the previous vendor tree untouched until a validated stage replaces it atomically" do
      vendor = File.join(@tmp, "vendor")
      write_fake_msb(File.join(vendor, "bin"), version: "0.6.6")
      staging = File.join(@tmp, "staging")
      write_fake_msb(File.join(staging, "bin")) # no firmware → invalid
      expect { tools.validate_staged!(staging, "v0.6.8") }.to raise_error(/libkrunfw/)
      expect(IO.popen([File.join(vendor, "bin", "msb"), "--version"], &:read)).to include("0.6.6")
      write_firmware(File.join(staging, "lib"))
      write_fake_msb(File.join(staging, "bin"), version: "0.6.8")
      tools.validate_staged!(staging, "v0.6.8")
      tools.promote!(staging, vendor)
      expect(IO.popen([File.join(vendor, "bin", "msb"), "--version"], &:read)).to include("0.6.8")
      expect(File.exist?(staging)).to be(false)
      expect(Dir["#{vendor}.old-*"]).to be_empty
    end

    it "restores the previous tree when the second rename fails mid-promotion" do
      vendor = File.join(@tmp, "vendor")
      write_fake_msb(File.join(vendor, "bin"), version: "0.6.6")
      staging = staged_tree
      calls = 0
      allow(File).to receive(:rename).and_wrap_original do |orig, from, to|
        calls += 1
        raise Errno::EIO, "injected fault" if calls == 2
        orig.call(from, to)
      end
      expect { tools.promote!(staging, vendor) }.to raise_error(Errno::EIO)
      # The old tree is back in place — the interruption cost nothing.
      expect(IO.popen([File.join(vendor, "bin", "msb"), "--version"], &:read)).to include("0.6.6")
    end

    it "names both paths instead of swallowing when the restore itself also fails" do
      vendor = File.join(@tmp, "vendor")
      write_fake_msb(File.join(vendor, "bin"), version: "0.6.6")
      staging = staged_tree
      calls = 0
      allow(File).to receive(:rename).and_wrap_original do |orig, from, to|
        calls += 1
        raise Errno::EIO, "injected fault" if calls >= 2
        orig.call(from, to)
      end
      expect { tools.promote!(staging, vendor) }
        .to raise_error(/AND restoring the previous vendor tree failed.*recover manually/m)
    end

    it "recovers an orphaned backup (crash between the renames) instead of deleting it" do
      vendor = File.join(@tmp, "vendor")
      backup = "#{vendor}.old-12345"
      write_fake_msb(File.join(backup, "bin"), version: "0.6.6")
      FileUtils.mkdir_p("#{vendor}.staging-99") # stale staging: discarded
      tools.recover_orphans!(vendor)
      expect(File.exist?(File.join(vendor, "bin", "msb"))).to be(true)
      expect(Dir["#{vendor}.staging-*"] + Dir["#{vendor}.old-*"]).to be_empty
    end

    it "drops backups made redundant by a live vendor tree" do
      vendor = File.join(@tmp, "vendor")
      write_fake_msb(File.join(vendor, "bin"))
      FileUtils.mkdir_p("#{vendor}.old-11")
      tools.recover_orphans!(vendor)
      expect(File.exist?(File.join(vendor, "bin", "msb"))).to be(true)
      expect(Dir["#{vendor}.old-*"]).to be_empty
    end
  end

  describe ".verify_manifest!" do
    it "passes a freshly staged + manifested tree and returns its file entries" do
      staging = staged_tree
      manifest!(staging)
      expect(tools.verify_manifest!(staging, expected_runtime_version: "v0.6.8"))
        .to contain_exactly("bin/msb", "lib/libkrunfw.5.dylib")
    end

    it "fails when the manifest is missing entirely" do
      expect { tools.verify_manifest!(staged_tree, expected_runtime_version: "v0.6.8") }
        .to raise_error(/manifest\.sha256 missing/)
    end

    it "fails a stale tree after a RUNTIME_VERSION bump (old manifest, new constant)" do
      staging = staged_tree(version: "0.6.6")
      manifest!(staging, runtime_version: "v0.6.6")
      expect { tools.verify_manifest!(staging, expected_runtime_version: "v0.6.8") }
        .to raise_error(/staged from runtime v0\.6\.6.*expects v0\.6\.8/)
    end

    it "fails a pre-versioning manifest that lacks the runtime_version header" do
      staging = staged_tree
      entries = Dir[File.join(staging, "{bin,lib}", "*")].sort.map do |f|
        "#{Digest::SHA256.file(f).hexdigest}  #{f.delete_prefix("#{staging}/")}\n"
      end
      File.write(File.join(staging, "manifest.sha256"), entries.join)
      expect { tools.verify_manifest!(staging, expected_runtime_version: "v0.6.8") }
        .to raise_error(/lacks a runtime_version header/)
    end

    it "fails closed on an unrecognized manifest line" do
      staging = staged_tree
      manifest!(staging)
      File.open(File.join(staging, "manifest.sha256"), "a") { |f| f.puts "mystery directive" }
      expect { tools.verify_manifest!(staging, expected_runtime_version: "v0.6.8") }
        .to raise_error(/unrecognized manifest line/)
    end

    it "fails when a vendored file was modified after staging" do
      staging = staged_tree
      manifest!(staging)
      File.write(File.join(staging, "bin", "msb"), "#!/bin/sh\necho tampered\n")
      expect { tools.verify_manifest!(staging, expected_runtime_version: "v0.6.8") }
        .to raise_error(/digest mismatch for bin\/msb/)
    end

    it "fails when the manifest lists no firmware (incomplete runtime must not ship)" do
      staging = File.join(@tmp, "staging")
      write_fake_msb(File.join(staging, "bin"))
      manifest!(staging)
      expect { tools.verify_manifest!(staging, expected_runtime_version: "v0.6.8") }
        .to raise_error(/lists no lib\/libkrunfw/)
    end

    it "fails when unlisted files appeared in the vendor tree" do
      staging = staged_tree
      manifest!(staging)
      File.write(File.join(staging, "bin", "extra"), "surprise")
      expect { tools.verify_manifest!(staging, expected_runtime_version: "v0.6.8") }
        .to raise_error(/not in the manifest: bin\/extra/)
    end
  end

  describe ".verify_gem_payload!" do
    # Build a minimal real gem whose payload is the given vendor tree, the way
    # the TOCTOU window would ship it.
    def build_gem_from(tree)
      gem_path = nil
      Dir.chdir(@tmp) do
        FileUtils.rm_rf(File.join(@tmp, "vendor"))
        FileUtils.cp_r(tree, File.join(@tmp, "vendor"))
        spec = Gem::Specification.new do |s|
          s.name = "payload-probe"
          s.version = "0.0.1"
          s.summary = "payload verification probe"
          s.authors = ["spec"]
          s.files = Dir["vendor/**/*"].select { |f| File.file?(f) }
        end
        gem_path = File.join(@tmp, Gem::Package.build(spec))
      end
      gem_path
    end

    it "passes when the packaged payload matches its manifest" do
      staging = staged_tree
      manifest!(staging)
      gem_path = build_gem_from(staging)
      expect { tools.verify_gem_payload!(gem_path, expected_runtime_version: "v0.6.8") }
        .not_to raise_error
    end

    it "catches a tree swapped/tampered between verification and packaging" do
      staging = staged_tree
      manifest!(staging)
      # The swap: after the manifest was verified, the tree mutates and THAT
      # is what gets packaged — post-build payload verification must catch it.
      File.write(File.join(staging, "bin", "msb"), "#!/bin/sh\necho swapped\n")
      gem_path = build_gem_from(staging)
      expect { tools.verify_gem_payload!(gem_path, expected_runtime_version: "v0.6.8") }
        .to raise_error(/digest mismatch for bin\/msb/)
    end
  end
end
