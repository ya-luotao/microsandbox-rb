# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open-uri"
require "rubygems/package"
require "zlib"

require_relative "../lib/microsandbox/binaries"

module Microsandbox
  module Binaries
    # Build-time tooling behind the Rakefile in binaries/ (NOT shipped in the
    # gem): downloads one upstream release bundle, verifies it against the
    # release's published `checksums.sha256`, stages `bin/msb` + `lib/libkrunfw*`
    # into `vendor/` and records a manifest the gem build re-verifies.
    #
    # Fail-closed throughout: a missing checksum entry, a digest mismatch, an
    # unexpected file in the bundle, or a manifest that doesn't match the tree
    # all raise — nothing unverified is ever packaged.
    module Vendor
      # RubyGems platform → upstream release asset triple.
      PLATFORMS = {
        "arm64-darwin" => "darwin-aarch64",
        "x86_64-linux-gnu" => "linux-x86_64",
        "aarch64-linux-gnu" => "linux-aarch64"
      }.freeze

      RELEASE_BASE = "https://github.com/superradcompany/microsandbox/releases/download"
      CHECKSUMS_ASSET = "checksums.sha256"
      MANIFEST_SCHEMA = 1
      # Committed copies of each release's checksums.sha256 (binaries/checksums/
      # <tag>.sha256). A GitHub release is mutable — an asset and its checksum
      # file can be re-uploaded together — so the digest we trust is the one
      # reviewed into this repo; the live file must still agree with it.
      CHECKSUMS_DIR = File.expand_path("../checksums", __dir__)

      module_function

      def platforms
        PLATFORMS.keys
      end

      # The RubyGems platform of the running host, in the spelling {PLATFORMS}
      # uses (`arm64-darwin-27` → `arm64-darwin`, `x86_64-linux` → `x86_64-linux-gnu`).
      # @return [String, nil] nil when the host has no prebuilt bundle
      def host_platform
        local = Gem::Platform.local
        candidate =
          case local.os
          when "darwin" then "#{local.cpu}-darwin"
          when "linux" then "#{local.cpu}-linux-#{local.version || "gnu"}"
          end
        PLATFORMS.key?(candidate) ? candidate : nil
      end

      def triple_for(platform)
        PLATFORMS.fetch(platform) do
          raise ArgumentError, "unsupported platform #{platform.inspect} (expected one of #{platforms.join(", ")})"
        end
      end

      def bundle_asset(platform)
        "microsandbox-#{triple_for(platform)}.tar.gz"
      end

      def asset_url(runtime_version, asset)
        "#{RELEASE_BASE}/#{runtime_version}/#{asset}"
      end

      # Default fetcher: GET a URL and return the body. GitHub release assets
      # redirect to a CDN host; open-uri follows https→https redirects.
      def fetch(url)
        URI.parse(url).open("rb", &:read)
      end

      def pinned_checksums_path(runtime_version)
        File.join(CHECKSUMS_DIR, "#{runtime_version}.sha256")
      end

      # The committed checksums document for +runtime_version+. Missing = the
      # release was never reviewed into this repo: fail closed.
      def pinned_checksums!(runtime_version)
        path = pinned_checksums_path(runtime_version)
        unless File.file?(path)
          raise "no committed checksums for #{runtime_version} at #{path} — download the release's " \
            "#{CHECKSUMS_ASSET}, review it, and commit it there before vendoring"
        end
        File.read(path)
      end

      # The published digest for +asset+ out of a `checksums.sha256` document
      # (sha256sum convention: "<hex>  <filename>" per line). A missing entry
      # raises rather than skipping verification.
      def expected_sha256!(checksums_text, asset)
        entry = checksums_text.each_line.find { |line| line.split.last == asset }
        raise "#{CHECKSUMS_ASSET} has no entry for #{asset} — refusing to vendor unverified binaries" unless entry
        digest = entry.split.first
        raise "malformed digest for #{asset} in #{CHECKSUMS_ASSET}: #{digest.inspect}" unless digest.match?(/\A\h{64}\z/)
        digest.downcase
      end

      # @return [String] the verified hex digest
      def verify_sha256!(data, expected, label)
        actual = Digest::SHA256.hexdigest(data)
        raise "sha256 mismatch for #{label}: expected #{expected}, got #{actual}" unless actual == expected.downcase
        actual
      end

      # Where a bundle entry lands relative to the vendor root. The upstream
      # bundle holds exactly the runtime binary and the firmware; anything else
      # is unexpected and aborts vendoring so a human reviews the new release.
      def route(entry_name)
        base = File.basename(entry_name)
        case base
        when "msb" then "bin/msb"
        when /\Alibkrunfw\./ then "lib/#{base}"
        else raise "unexpected entry #{entry_name.inspect} in runtime bundle — refusing to vendor unknown files"
        end
      end

      # Extract an already-verified `.tar.gz` bundle into +dest_dir+ (which must
      # not exist yet — a leftover from an interrupted run is stale state, not a
      # resume point). Returns { "bin/msb" => sha256, "lib/libkrunfw…" => sha256 }.
      def extract_bundle!(tgz_bytes, dest_dir)
        raise "staging dir already exists: #{dest_dir}" if File.exist?(dest_dir)
        files = {}
        Zlib::GzipReader.wrap(StringIO.new(tgz_bytes)) do |gz|
          Gem::Package::TarReader.new(gz) do |tar|
            tar.each do |entry|
              next if entry.directory?
              raise "refusing non-regular entry #{entry.full_name.inspect} in runtime bundle" unless entry.file?
              rel = route(entry.full_name)
              raise "duplicate entry #{rel} in runtime bundle" if files.key?(rel)
              data = entry.read || "".b
              target = File.join(dest_dir, rel)
              FileUtils.mkdir_p(File.dirname(target))
              File.binwrite(target, data)
              File.chmod(0o755, target)
              files[rel] = Digest::SHA256.hexdigest(data)
            end
          end
        end
        raise "runtime bundle is missing bin/msb" unless files.key?("bin/msb")
        raise "runtime bundle is missing lib/libkrunfw*" unless files.keys.any? { |rel| rel.start_with?("lib/libkrunfw") }
        files
      end

      def write_manifest!(dir, platform:, runtime_version:, bundle_asset:, bundle_sha256:, files:)
        manifest = {
          "schema" => MANIFEST_SCHEMA,
          "platform" => platform,
          "runtime_version" => runtime_version,
          "bundle_asset" => bundle_asset,
          "bundle_sha256" => bundle_sha256,
          "files" => files.sort.to_h
        }
        File.write(File.join(dir, Binaries::MANIFEST), JSON.pretty_generate(manifest) + "\n")
        manifest
      end

      # Check a vendored tree against its manifest: the manifest must be for
      # +platform+ and +runtime_version+, every listed file must exist with the
      # recorded digest, the tree must contain nothing else, and the runtime must
      # be complete. Returns the manifest.
      def verify_manifest!(vendor_dir, platform:, runtime_version:)
        manifest_path = File.join(vendor_dir, Binaries::MANIFEST)
        raise "no #{Binaries::MANIFEST} in #{vendor_dir} — run `rake vendor[#{platform}]` first" unless File.file?(manifest_path)
        manifest = JSON.parse(File.read(manifest_path))
        raise "unsupported manifest schema #{manifest["schema"].inspect}" unless manifest["schema"] == MANIFEST_SCHEMA
        raise "vendored tree is for #{manifest["platform"]}, not #{platform}" unless manifest["platform"] == platform
        unless manifest["runtime_version"] == runtime_version
          raise "vendored tree is from runtime #{manifest["runtime_version"]}, but RUNTIME_VERSION is #{runtime_version} — re-run `rake vendor[#{platform}]`"
        end
        files = manifest.fetch("files")
        raise "manifest lists no bin/msb" unless files.key?("bin/msb")
        raise "manifest lists no lib/libkrunfw*" unless files.keys.any? { |rel| rel.start_with?("lib/libkrunfw") }
        files.each do |rel, expected|
          path = File.join(vendor_dir, rel)
          # lstat: a symlink would pass File.file? (and be packed AS a symlink by
          # RubyGems), so only regular files count.
          raise "vendored file missing or not a regular file: #{rel}" unless File.exist?(path) && File.lstat(path).file?
          verify_sha256!(File.binread(path), expected, rel)
        end
        present = Dir.chdir(vendor_dir) { Dir["**/*"].reject { |f| File.lstat(f).directory? } } - [Binaries::MANIFEST]
        extra = present - files.keys
        raise "unexpected files in #{vendor_dir}: #{extra.join(", ")}" unless extra.empty?
        manifest
      end

      # Download + verify + stage the bundle for +platform+, then atomically
      # replace +vendor_dir+. +fetch+ is injectable for tests.
      def vendor!(platform, runtime_version: Binaries::RUNTIME_VERSION, vendor_dir: Binaries::ROOT,
        fetch: method(:fetch), pinned_checksums: pinned_checksums!(runtime_version), log: $stderr)
        asset = bundle_asset(platform)
        expected = expected_sha256!(pinned_checksums, asset)
        log.puts "[binaries] fetching #{CHECKSUMS_ASSET} for #{runtime_version}"
        live = expected_sha256!(fetch.call(asset_url(runtime_version, CHECKSUMS_ASSET)), asset)
        unless live == expected
          raise "upstream #{CHECKSUMS_ASSET} now lists #{asset} as #{live}, but the committed " \
            "#{File.basename(pinned_checksums_path(runtime_version))} says #{expected} — the release " \
            "asset was changed after review; refusing to vendor"
        end
        log.puts "[binaries] fetching #{asset}"
        data = fetch.call(asset_url(runtime_version, asset))
        bundle_sha256 = verify_sha256!(data, expected, asset)
        log.puts "[binaries] verified #{asset} sha256=#{bundle_sha256}"

        staging = "#{vendor_dir}.staging-#{Process.pid}"
        FileUtils.rm_rf(staging)
        files = extract_bundle!(data, staging)
        write_manifest!(staging, platform: platform, runtime_version: runtime_version,
          bundle_asset: asset, bundle_sha256: bundle_sha256, files: files)
        verify_manifest!(staging, platform: platform, runtime_version: runtime_version)

        FileUtils.rm_rf(vendor_dir)
        File.rename(staging, vendor_dir)
        log.puts "[binaries] vendored #{platform} runtime into #{vendor_dir}: #{files.keys.join(", ")}"
        files
      ensure
        FileUtils.rm_rf(staging) if staging && File.exist?(staging)
      end
    end
  end
end
