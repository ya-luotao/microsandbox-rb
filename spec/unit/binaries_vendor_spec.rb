# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "zlib"
require "rubygems/package"
require_relative "../../binaries/tasks/vendor"

# The build-time tooling behind binaries/Rakefile. Its job is to be fail-closed:
# every way an unverified or incomplete runtime could end up in a gem is
# exercised here against synthetic bundles (no network, no real binaries).
RSpec.describe Microsandbox::Binaries::Vendor do
  let(:vendor_mod) { Microsandbox::Binaries::Vendor }

  def tgz(entries)
    io = StringIO.new("".b)
    Zlib::GzipWriter.wrap(io) do |gz|
      Gem::Package::TarWriter.new(gz) do |tar|
        entries.each do |name, data|
          tar.add_file_simple(name, 0o755, data.bytesize) { |f| f.write(data) }
        end
      end
    end
    io.string
  end

  let(:bundle) { tgz("msb" => "fake-msb".b, "libkrunfw.5.dylib" => "fake-fw".b) }
  let(:bundle_sha) { Digest::SHA256.hexdigest(bundle) }
  let(:checksums) { "#{bundle_sha}  microsandbox-darwin-aarch64.tar.gz\n0123  something-else\n" }

  describe ".host_platform" do
    def with_local(platform)
      allow(Gem::Platform).to receive(:local).and_return(Gem::Platform.new(platform))
      vendor_mod.host_platform
    end

    it "maps the host to the spelling the release bundles use" do
      expect(with_local("arm64-darwin-27")).to eq("arm64-darwin")
      expect(with_local("x86_64-linux")).to eq("x86_64-linux-gnu")
      expect(with_local("x86_64-linux-gnu")).to eq("x86_64-linux-gnu")
      expect(with_local("aarch64-linux")).to eq("aarch64-linux-gnu")
    end

    it "is nil on hosts without a prebuilt bundle" do
      expect(with_local("x86_64-linux-musl")).to be_nil
      expect(with_local("x86_64-darwin-23")).to be_nil
      expect(with_local("x64-mingw-ucrt")).to be_nil
    end
  end

  describe ".bundle_asset" do
    it "names the upstream release asset for each supported platform" do
      expect(vendor_mod.bundle_asset("arm64-darwin")).to eq("microsandbox-darwin-aarch64.tar.gz")
      expect(vendor_mod.bundle_asset("x86_64-linux-gnu")).to eq("microsandbox-linux-x86_64.tar.gz")
      expect(vendor_mod.bundle_asset("aarch64-linux-gnu")).to eq("microsandbox-linux-aarch64.tar.gz")
    end

    it "rejects unsupported platforms" do
      expect { vendor_mod.bundle_asset("x86_64-linux-musl") }.to raise_error(ArgumentError, /unsupported platform/)
    end
  end

  describe ".expected_sha256!" do
    it "reads the sha256sum-style entry for the asset" do
      expect(vendor_mod.expected_sha256!(checksums, "microsandbox-darwin-aarch64.tar.gz")).to eq(bundle_sha)
    end

    it "fails closed when the asset has no entry" do
      expect { vendor_mod.expected_sha256!(checksums, "microsandbox-linux-x86_64.tar.gz") }
        .to raise_error(/no entry for microsandbox-linux-x86_64\.tar\.gz/)
    end

    it "rejects a malformed digest" do
      expect { vendor_mod.expected_sha256!(checksums, "something-else") }.to raise_error(/malformed digest/)
    end
  end

  describe ".verify_sha256!" do
    it "raises on mismatch and returns the digest on match" do
      expect(vendor_mod.verify_sha256!("abc", Digest::SHA256.hexdigest("abc"), "x")).to eq(Digest::SHA256.hexdigest("abc"))
      expect { vendor_mod.verify_sha256!("abc", "0" * 64, "x") }.to raise_error(/sha256 mismatch for x/)
    end
  end

  describe ".extract_bundle!" do
    it "routes msb to bin/ and the firmware to lib/, executable, and returns per-file digests" do
      Dir.mktmpdir do |dir|
        dest = File.join(dir, "vendor")
        files = vendor_mod.extract_bundle!(bundle, dest)
        expect(files.keys).to contain_exactly("bin/msb", "lib/libkrunfw.5.dylib")
        expect(File.binread(File.join(dest, "bin/msb"))).to eq("fake-msb")
        expect(File.stat(File.join(dest, "bin/msb")).mode & 0o111).not_to eq(0)
        expect(files["bin/msb"]).to eq(Digest::SHA256.hexdigest("fake-msb"))
      end
    end

    it "refuses unknown files in the bundle instead of shipping them" do
      Dir.mktmpdir do |dir|
        odd = tgz("msb" => "x", "libkrunfw.5.dylib" => "y", "msb-metrics" => "z")
        expect { vendor_mod.extract_bundle!(odd, File.join(dir, "v")) }.to raise_error(/unexpected entry "msb-metrics"/)
      end
    end

    it "refuses an incomplete runtime" do
      Dir.mktmpdir do |dir|
        expect { vendor_mod.extract_bundle!(tgz("msb" => "x"), File.join(dir, "a")) }.to raise_error(/missing lib\/libkrunfw/)
        expect { vendor_mod.extract_bundle!(tgz("libkrunfw.so.5.6.1" => "x"), File.join(dir, "b")) }.to raise_error(/missing bin\/msb/)
      end
    end

    it "refuses to extract over an existing directory" do
      Dir.mktmpdir do |dir|
        expect { vendor_mod.extract_bundle!(bundle, dir) }.to raise_error(/already exists/)
      end
    end
  end

  describe ".vendor! / .verify_manifest!" do
    let(:fetch) do
      lambda do |url|
        case url
        when %r{/v0\.6\.9/checksums\.sha256\z} then checksums
        when %r{/v0\.6\.9/microsandbox-darwin-aarch64\.tar\.gz\z} then bundle
        else raise "unexpected fetch #{url}"
        end
      end
    end

    def vendor!(dir, fetch: self.fetch, platform: "arm64-darwin", version: "v0.6.9", pinned: checksums)
      vendor_mod.vendor!(platform, runtime_version: version, vendor_dir: File.join(dir, "vendor"),
        fetch: fetch, pinned_checksums: pinned, log: StringIO.new)
    end

    it "trusts the committed checksums and refuses when the live release disagrees" do
      Dir.mktmpdir do |dir|
        reuploaded = ->(url) { url.end_with?("checksums.sha256") ? "#{"0" * 64}  microsandbox-darwin-aarch64.tar.gz\n" : fetch.call(url) }
        expect { vendor!(dir, fetch: reuploaded) }.to raise_error(/release asset was changed after review/)
        expect(Dir.children(dir)).to be_empty
      end
    end

    it "fails closed when no checksums were committed for the runtime version" do
      expect { vendor_mod.pinned_checksums!("v0.0.0") }.to raise_error(/no committed checksums for v0\.0\.0/)
    end

    it "ships a committed checksums file for the current RUNTIME_VERSION that matches the manifest format" do
      text = vendor_mod.pinned_checksums!(Microsandbox::Binaries::RUNTIME_VERSION)
      vendor_mod.platforms.each do |platform|
        expect(vendor_mod.expected_sha256!(text, vendor_mod.bundle_asset(platform))).to match(/\A\h{64}\z/)
      end
    end

    it "downloads, verifies, stages and writes a manifest the build re-verifies" do
      Dir.mktmpdir do |dir|
        vendor!(dir)
        vendor_dir = File.join(dir, "vendor")
        manifest = vendor_mod.verify_manifest!(vendor_dir, platform: "arm64-darwin", runtime_version: "v0.6.9")
        expect(manifest["runtime_version"]).to eq("v0.6.9")
        expect(manifest["platform"]).to eq("arm64-darwin")
        expect(manifest["bundle_sha256"]).to eq(bundle_sha)
        expect(manifest["files"].keys).to eq(["bin/msb", "lib/libkrunfw.5.dylib"])
        expect(Dir.children(dir)).to eq(["vendor"]) # no staging leftovers
      end
    end

    it "fails closed on a tampered bundle and leaves nothing behind" do
      Dir.mktmpdir do |dir|
        bad = fetch
        tampered = ->(url) { url.end_with?(".tar.gz") ? tgz("msb" => "evil", "libkrunfw.5.dylib" => "y") : bad.call(url) }
        expect { vendor!(dir, fetch: tampered) }.to raise_error(/sha256 mismatch/)
        expect(Dir.children(dir)).to be_empty
      end
    end

    it "fails closed when the release publishes no digest for the asset" do
      Dir.mktmpdir do |dir|
        no_entry = ->(url) { url.end_with?("checksums.sha256") ? "deadbeef  other.tar.gz\n" : fetch.call(url) }
        expect { vendor!(dir, fetch: no_entry) }.to raise_error(/no entry for/)
        expect(Dir.children(dir)).to be_empty
      end
    end

    it "keeps the previous vendored tree when a re-vendor fails" do
      Dir.mktmpdir do |dir|
        vendor!(dir)
        broken = ->(_url) { raise IOError, "network down" }
        expect { vendor!(dir, fetch: broken) }.to raise_error(IOError)
        expect(File).to exist(File.join(dir, "vendor", "bin", "msb"))
        expect(Dir.children(dir)).to eq(["vendor"])
      end
    end

    it "rejects a vendored tree whose files were modified after staging" do
      Dir.mktmpdir do |dir|
        vendor!(dir)
        File.binwrite(File.join(dir, "vendor", "bin", "msb"), "swapped")
        expect { vendor_mod.verify_manifest!(File.join(dir, "vendor"), platform: "arm64-darwin", runtime_version: "v0.6.9") }
          .to raise_error(/sha256 mismatch for bin\/msb/)
      end
    end

    it "rejects extra files, a missing file, the wrong platform and a stale runtime version" do
      Dir.mktmpdir do |dir|
        vendor!(dir)
        vendor_dir = File.join(dir, "vendor")
        File.write(File.join(vendor_dir, "bin", "extra"), "x")
        expect { vendor_mod.verify_manifest!(vendor_dir, platform: "arm64-darwin", runtime_version: "v0.6.9") }
          .to raise_error(/unexpected files .*bin\/extra/)
        File.delete(File.join(vendor_dir, "bin", "extra"))

        expect { vendor_mod.verify_manifest!(vendor_dir, platform: "x86_64-linux-gnu", runtime_version: "v0.6.9") }
          .to raise_error(/is for arm64-darwin, not x86_64-linux-gnu/)
        expect { vendor_mod.verify_manifest!(vendor_dir, platform: "arm64-darwin", runtime_version: "v0.7.0") }
          .to raise_error(/from runtime v0\.6\.9, but RUNTIME_VERSION is v0\.7\.0/)

        File.delete(File.join(vendor_dir, "lib", "libkrunfw.5.dylib"))
        expect { vendor_mod.verify_manifest!(vendor_dir, platform: "arm64-darwin", runtime_version: "v0.6.9") }
          .to raise_error(/vendored file missing or not a regular file: lib\/libkrunfw\.5\.dylib/)
      end
    end

    it "rejects a symlink standing in for a vendored file" do
      Dir.mktmpdir do |dir|
        vendor!(dir)
        msb = File.join(dir, "vendor", "bin", "msb")
        File.rename(msb, "#{msb}.real")
        File.symlink("#{msb}.real", msb)
        expect { vendor_mod.verify_manifest!(File.join(dir, "vendor"), platform: "arm64-darwin", runtime_version: "v0.6.9") }
          .to raise_error(/not a regular file: bin\/msb|unexpected files/)
      end
    end

    it "requires a manifest at all" do
      Dir.mktmpdir do |dir|
        expect { vendor_mod.verify_manifest!(dir, platform: "arm64-darwin", runtime_version: "v0.6.9") }
          .to raise_error(/no manifest\.json/)
      end
    end
  end

  describe "Microsandbox::Binaries (runtime accessors)" do
    it "exposes the vendored files once a tree is in place" do
      Dir.mktmpdir do |dir|
        vendor_dir = File.join(dir, "vendor")
        vendor_mod.vendor!("arm64-darwin", runtime_version: "v0.6.9", vendor_dir: vendor_dir,
          fetch: ->(url) { url.end_with?(".sha256") ? checksums : bundle }, pinned_checksums: checksums, log: StringIO.new)
        stub_const("Microsandbox::Binaries::ROOT", vendor_dir)
        expect(Microsandbox::Binaries.msb_path).to eq(File.join(vendor_dir, "bin", "msb"))
        expect(Microsandbox::Binaries.libkrunfw_path).to eq(File.join(vendor_dir, "lib", "libkrunfw.5.dylib"))
        expect(Microsandbox::Binaries).to be_available
        expect(Microsandbox::Binaries.platform).to eq("arm64-darwin")
        expect(Microsandbox::Binaries.manifest["runtime_version"]).to eq("v0.6.9")
      end
    end

    it "reports nothing on a checkout without a vendored runtime" do
      Dir.mktmpdir do |dir|
        stub_const("Microsandbox::Binaries::ROOT", File.join(dir, "missing"))
        expect(Microsandbox::Binaries.msb_path).to be_nil
        expect(Microsandbox::Binaries.libkrunfw_path).to be_nil
        expect(Microsandbox::Binaries).not_to be_available
        expect(Microsandbox::Binaries.manifest).to be_nil
        expect(Microsandbox::Binaries.platform).to be_nil
      end
    end
  end
end
