# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "json"
require "zlib"
require "rubygems/package"
require_relative "../../binaries/tasks/vendor"

# Fail-closed guards in binaries/tasks/vendor.rb that binaries_vendor_spec.rb
# does not pin: each example fails if the guard it names is removed.
RSpec.describe Microsandbox::Binaries::Vendor, "unpinned fail-closed guards" do
  let(:vendor_mod) { Microsandbox::Binaries::Vendor }
  let(:asset) { "microsandbox-darwin-aarch64.tar.gz" }

  def tar_gz
    io = StringIO.new("".b)
    Zlib::GzipWriter.wrap(io) { |gz| Gem::Package::TarWriter.new(gz) { |tar| yield tar } }
    io.string
  end

  def tgz(entries)
    tar_gz { |tar| entries.each { |name, data| tar.add_file_simple(name, 0o755, data.bytesize) { |f| f.write(data) } } }
  end

  def vendor!(dir, bundle)
    checksums = "#{Digest::SHA256.hexdigest(bundle)}  #{asset}\n"
    vendor_mod.vendor!("arm64-darwin", runtime_version: "v0.6.9", vendor_dir: File.join(dir, "vendor"),
      fetch: ->(url) { url.end_with?(".sha256") ? checksums : bundle }, pinned_checksums: checksums, log: StringIO.new)
  end

  let(:good) { tgz("msb" => "fake-msb", "libkrunfw.5.dylib" => "fake-fw") }

  describe ".extract_bundle!" do
    it "refuses a symlink entry even when it is named like the runtime" do
      evil = tar_gz do |tar|
        tar.add_symlink("msb", "/etc/passwd", 0o777)
        tar.add_file_simple("libkrunfw.5.dylib", 0o644, 1) { |f| f.write("y") }
      end
      Dir.mktmpdir do |dir|
        expect { vendor_mod.extract_bundle!(evil, File.join(dir, "v")) }.to raise_error(/refusing non-regular entry "msb"/)
      end
    end

    it "refuses two entries that route to the same vendored file" do
      Dir.mktmpdir do |dir|
        dup = tgz("a/msb" => "first", "b/msb" => "second", "libkrunfw.5.dylib" => "y")
        expect { vendor_mod.extract_bundle!(dup, File.join(dir, "v")) }.to raise_error(/duplicate entry bin\/msb/)
      end
    end

    it "only routes names that START with libkrunfw. into lib/" do
      Dir.mktmpdir do |dir|
        odd = tgz("msb" => "x", "libkrunfw.5.dylib" => "y", "evil-libkrunfw.sh" => "z")
        expect { vendor_mod.extract_bundle!(odd, File.join(dir, "v")) }.to raise_error(/unexpected entry "evil-libkrunfw.sh"/)
      end
    end
  end

  describe ".expected_sha256!" do
    it "matches the asset name exactly, not as a substring" do
      text = "#{"a" * 64}  #{asset}.sig\n#{"b" * 64}  prefix-#{asset}\n#{"c" * 64}  #{asset}\n"
      expect(vendor_mod.expected_sha256!(text, asset)).to eq("c" * 64)
    end
  end

  describe ".verify_manifest!" do
    def rewrite_manifest(vendor_dir)
      path = File.join(vendor_dir, Microsandbox::Binaries::MANIFEST)
      manifest = JSON.parse(File.read(path))
      yield manifest
      File.write(path, JSON.generate(manifest))
    end

    def verify(vendor_dir)
      vendor_mod.verify_manifest!(vendor_dir, platform: "arm64-darwin", runtime_version: "v0.6.9")
    end

    it "rejects a manifest schema it does not know" do
      Dir.mktmpdir do |dir|
        vendor!(dir, good)
        rewrite_manifest(File.join(dir, "vendor")) { |m| m["schema"] = 2 }
        expect { verify(File.join(dir, "vendor")) }.to raise_error(/unsupported manifest schema 2/)
      end
    end

    it "rejects a manifest that lists no msb / no firmware" do
      Dir.mktmpdir do |dir|
        vendor!(dir, good)
        vendor_dir = File.join(dir, "vendor")
        rewrite_manifest(vendor_dir) { |m| m["files"].delete("bin/msb") }
        File.delete(File.join(vendor_dir, "bin", "msb"))
        expect { verify(vendor_dir) }.to raise_error(/manifest lists no bin\/msb/)
      end
      Dir.mktmpdir do |dir|
        vendor!(dir, good)
        vendor_dir = File.join(dir, "vendor")
        rewrite_manifest(vendor_dir) { |m| m["files"].delete("lib/libkrunfw.5.dylib") }
        File.delete(File.join(vendor_dir, "lib", "libkrunfw.5.dylib"))
        expect { verify(vendor_dir) }.to raise_error(/manifest lists no lib\/libkrunfw/)
      end
    end

    it "rejects a symlink to an identical file OUTSIDE the tree (nothing extra in vendor/)" do
      Dir.mktmpdir do |dir|
        vendor!(dir, good)
        msb = File.join(dir, "vendor", "bin", "msb")
        outside = File.join(dir, "elsewhere-msb")
        File.rename(msb, outside)
        File.symlink(outside, msb)
        expect { verify(File.join(dir, "vendor")) }.to raise_error(/not a regular file: bin\/msb/)
      end
    end
  end

  describe ".vendor!" do
    # Digest-valid (so it gets past verification into the staging step) but
    # not extractable: the failure happens AFTER the staging dir exists.
    let(:unextractable) { tgz("msb" => "x", "libkrunfw.5.dylib" => "y", "surprise" => "z") }

    it "removes the staging dir when extraction fails after the digest check" do
      Dir.mktmpdir do |dir|
        expect { vendor!(dir, unextractable) }.to raise_error(/unexpected entry "surprise"/)
        expect(Dir.children(dir)).to be_empty
      end
    end

    it "keeps the previous vendored tree when extraction fails after the digest check" do
      Dir.mktmpdir do |dir|
        vendor!(dir, good)
        expect { vendor!(dir, unextractable) }.to raise_error(/unexpected entry "surprise"/)
        expect(File.binread(File.join(dir, "vendor", "bin", "msb"))).to eq("fake-msb")
        expect(Dir.children(dir)).to eq(["vendor"])
      end
    end
  end
end
