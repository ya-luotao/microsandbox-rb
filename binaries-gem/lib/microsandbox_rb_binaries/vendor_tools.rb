# frozen_string_literal: true

require "digest"
require "fileutils"

module MicrosandboxRbBinaries
  # Build-time helpers behind `rake vendor` and the platform-gem build. NOT
  # packaged into the gem — this is repo tooling, extracted from the Rakefile
  # so the fail-closed behavior is unit-testable.
  #
  # Invariants the pipeline enforces:
  # - nothing unverified is ever installed: a missing checksum entry fails as
  #   hard as a mismatching one;
  # - the live `vendor/` tree is replaced atomically (stage into a fresh
  #   sibling, validate the complete file set + msb version, then rename), so
  #   an interrupted or failed run can never leave a partial tree that a later
  #   `gem build` would package;
  # - `gem build` revalidates a sha256 manifest written at stage time, so
  #   stale or tampered vendor bytes fail the build instead of shipping.
  module VendorTools
    MANIFEST_NAME = "manifest.sha256"

    module_function

    # The published digest for +asset+ out of a `checksums.sha256` document
    # (sha256sum convention: "<hex>  <filename>" per line). Fail-closed: a
    # missing entry raises rather than skipping verification.
    def expected_sha256!(checksums_text, asset)
      entry = checksums_text.lines.find { |line| line.split.last == asset }
      unless entry
        raise "checksums.sha256 has no entry for #{asset} — refusing to install unverified binaries"
      end
      entry.split.first
    end

    # Verify +data+ against +expected+ (hex sha256), raising on mismatch.
    def verify_sha256!(data, expected, label)
      actual = Digest::SHA256.hexdigest(data)
      unless actual.casecmp?(expected)
        raise "sha256 mismatch for #{label}: expected #{expected}, got #{actual}"
      end
      actual
    end

    # Extract an already-verified bundle tarball into a FRESH staging dir,
    # routing files by name like the core crate's extract_bundle (libkrunfw* →
    # lib/, everything else → bin/). The staging dir must not exist yet — a
    # leftover from a crashed run is stale state, not a resume point.
    def stage_bundle!(tarball_path, staging_dir)
      raise "staging dir already exists: #{staging_dir}" if File.exist?(staging_dir)
      bin_dir = File.join(staging_dir, "bin")
      lib_dir = File.join(staging_dir, "lib")
      FileUtils.mkdir_p([bin_dir, lib_dir])
      extract_dir = File.join(staging_dir, ".extract")
      FileUtils.mkdir_p(extract_dir)
      system("tar", "-xzf", tarball_path, "-C", extract_dir, exception: true)
      Dir[File.join(extract_dir, "**", "*")].each do |f|
        next unless File.file?(f)
        name = File.basename(f)
        dest = name.start_with?("libkrunfw") ? lib_dir : bin_dir
        FileUtils.cp(f, File.join(dest, name))
        FileUtils.chmod(0o755, File.join(dest, name))
      end
      FileUtils.rm_rf(extract_dir)
      nil
    end

    # The staged tree must hold the COMPLETE runtime — `bin/msb` plus at least
    # one `lib/libkrunfw*` — and the staged msb must report exactly the
    # expected runtime version. Anything less fails before promotion, so the
    # live vendor tree can never go partial or version-skewed.
    def validate_staged!(staging_dir, expected_runtime_version)
      msb = File.join(staging_dir, "bin", "msb")
      raise "staged tree is missing bin/msb" unless File.file?(msb)
      firmware = Dir[File.join(staging_dir, "lib", "libkrunfw*")].select { |f| File.file?(f) }
      raise "staged tree is missing lib/libkrunfw* firmware" if firmware.empty?
      expected = expected_runtime_version.delete_prefix("v")
      output = begin
        IO.popen([msb, "--version"], err: File::NULL, &:read)
      rescue SystemCallError
        nil
      end
      actual = output&.[](/\bmsb\s+(\S+)/, 1)
      unless actual == expected
        raise "staged msb reports version #{actual.inspect}, expected #{expected}"
      end
      nil
    end

    # Record a sha256 manifest of every staged runtime file (relative paths),
    # for `gem build` to revalidate.
    def write_manifest!(staging_dir)
      entries = Dir[File.join(staging_dir, "{bin,lib}", "*")].select { |f| File.file?(f) }.sort
      lines = entries.map do |f|
        rel = f.delete_prefix("#{staging_dir}/")
        "#{Digest::SHA256.file(f).hexdigest}  #{rel}\n"
      end
      File.write(File.join(staging_dir, MANIFEST_NAME), lines.join)
      nil
    end

    # Promote a validated staging tree to the live vendor dir: move any old
    # tree aside, rename staging in, drop the old tree. A crash between the
    # renames leaves NO vendor dir (fail-closed — the gem build then refuses),
    # never a mixed one.
    def promote!(staging_dir, vendor_dir)
      old = "#{vendor_dir}.old-#{Process.pid}"
      File.rename(vendor_dir, old) if File.exist?(vendor_dir)
      File.rename(staging_dir, vendor_dir)
      FileUtils.rm_rf(old)
      nil
    end

    # `gem build`-time revalidation of the vendor tree against its manifest:
    # the manifest must exist, must name both `bin/msb` and a `lib/libkrunfw*`
    # firmware file, every entry must exist with a matching digest, and no
    # unlisted runtime file may have appeared.
    def verify_manifest!(vendor_dir)
      manifest = File.join(vendor_dir, MANIFEST_NAME)
      unless File.file?(manifest)
        raise "#{vendor_dir}/#{MANIFEST_NAME} missing — run `rake vendor` before building the platform gem"
      end
      entries = File.readlines(manifest).to_h do |line|
        sha, rel = line.split(" ", 2)
        [rel.strip, sha]
      end
      unless entries.key?("bin/msb")
        raise "vendor manifest lists no bin/msb"
      end
      unless entries.keys.any? { |rel| rel.start_with?("lib/libkrunfw") }
        raise "vendor manifest lists no lib/libkrunfw* firmware"
      end
      entries.each do |rel, sha|
        f = File.join(vendor_dir, rel)
        raise "vendor file missing: #{rel} — re-run `rake vendor`" unless File.file?(f)
        actual = Digest::SHA256.file(f).hexdigest
        unless actual.casecmp?(sha)
          raise "vendor file digest mismatch for #{rel} — re-run `rake vendor`"
        end
      end
      on_disk = Dir[File.join(vendor_dir, "{bin,lib}", "*")].select { |f| File.file?(f) }
        .map { |f| f.delete_prefix("#{vendor_dir}/") }
      extras = on_disk - entries.keys
      unless extras.empty?
        raise "vendor tree has files not in the manifest: #{extras.join(", ")} — re-run `rake vendor`"
      end
      entries.keys
    end
  end
end
