# frozen_string_literal: true

require "digest"
require "fileutils"
require "timeout"
require "tmpdir"

module MicrosandboxRbBinaries
  # Build-time helpers behind `rake vendor` and the platform-gem build. NOT
  # packaged into the gem — this is repo tooling, extracted from the Rakefile
  # so the fail-closed behavior is unit-testable.
  #
  # Invariants the pipeline enforces:
  # - nothing unverified is ever installed: a missing checksum entry fails as
  #   hard as a mismatching one;
  # - the live `vendor/` tree is replaced atomically (stage into a fresh
  #   sibling, validate the complete file set + msb version under a bounded
  #   timeout, then rename), an interrupted promotion restores the previous
  #   tree (or names both paths for manual recovery), and orphaned backups
  #   from a crash are recovered — not deleted — on the next run;
  # - the manifest binds the vendor tree to the runtime release it was staged
  #   from (version + verified release-bundle digest), so a stale tree fails
  #   the gem build after a RUNTIME_VERSION bump instead of shipping;
  # - `gem build` runs under the same file lock as `rake vendor` and the
  #   finished gem's payload is re-verified against the packaged manifest,
  #   closing the window between gemspec-time verification and RubyGems'
  #   file reads.
  module VendorTools
    MANIFEST_NAME = "manifest.sha256"
    LOCK_NAME = ".vendor.lock"

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
    # expected runtime version WITH a successful exit status, under a bounded
    # timeout (same contract as the SDK's runtime check: valid-looking output
    # from a binary that exits nonzero or hangs is a broken binary, not a
    # validated one). Anything less fails before promotion.
    def validate_staged!(staging_dir, expected_runtime_version, timeout: 10)
      msb = File.join(staging_dir, "bin", "msb")
      raise "staged tree is missing bin/msb" unless File.file?(msb)
      firmware = Dir[File.join(staging_dir, "lib", "libkrunfw*")].select { |f| File.file?(f) }
      raise "staged tree is missing lib/libkrunfw* firmware" if firmware.empty?
      expected = expected_runtime_version.delete_prefix("v")
      output, status = run_version_probe(msb, timeout: timeout)
      if status == :timeout
        raise "staged msb did not finish `--version` within #{timeout}s — refusing to promote"
      end
      unless status&.success?
        raise "staged msb exited #{status.respond_to?(:exitstatus) ? status.exitstatus : "unspawnable"} " \
          "from `--version` — refusing to promote"
      end
      actual = output[/\bmsb\s+(\S+)/, 1]
      unless actual == expected
        raise "staged msb reports version #{actual.inspect}, expected #{expected}"
      end
      nil
    end

    # Record a manifest binding the staged runtime files to the release they
    # came from: a version + verified-bundle-digest header, then one sha256
    # line per file (relative paths). `gem build` revalidates all of it.
    def write_manifest!(staging_dir, runtime_version:, bundle_sha256:)
      entries = Dir[File.join(staging_dir, "{bin,lib}", "*")].select { |f| File.file?(f) }.sort
      lines = ["runtime_version #{runtime_version}\n", "bundle_sha256 #{bundle_sha256}\n"]
      lines += entries.map do |f|
        rel = f.delete_prefix("#{staging_dir}/")
        "#{Digest::SHA256.file(f).hexdigest}  #{rel}\n"
      end
      File.write(File.join(staging_dir, MANIFEST_NAME), lines.join)
      nil
    end

    # Promote a validated staging tree to the live vendor dir. The old tree is
    # moved aside first; if the second rename fails, the old tree is restored
    # (and if THAT fails too, both paths are named for manual recovery — never
    # swallowed). A crash between the renames leaves an orphaned backup that
    # {recover_orphans!} restores on the next run.
    def promote!(staging_dir, vendor_dir)
      old = "#{vendor_dir}.old-#{Process.pid}"
      had_old = File.exist?(vendor_dir)
      File.rename(vendor_dir, old) if had_old
      begin
        File.rename(staging_dir, vendor_dir)
      rescue => promote_error
        if had_old
          begin
            File.rename(old, vendor_dir)
          rescue => restore_error
            raise "promotion failed (#{promote_error.message}) AND restoring the previous " \
              "vendor tree failed (#{restore_error.message}) — recover manually: " \
              "mv #{old} #{vendor_dir}"
          end
        end
        raise
      end
      FileUtils.rm_rf(old)
      nil
    end

    # Crash recovery, run before anything else touches the trees: stale
    # staging dirs are always discarded (never resume points), but an orphaned
    # `.old-*` backup is RESTORED when the live vendor dir is missing — a
    # crash between promote!'s two renames must not cost the previous good
    # tree. Backups made redundant by a live vendor dir are dropped.
    def recover_orphans!(vendor_dir)
      FileUtils.rm_rf(Dir["#{vendor_dir}.staging-*"])
      backups = Dir["#{vendor_dir}.old-*"].sort_by { |d| File.mtime(d) }
      if !File.exist?(vendor_dir) && (latest = backups.pop)
        File.rename(latest, vendor_dir)
      end
      FileUtils.rm_rf(backups)
      nil
    end

    # `gem build`-time revalidation of a vendor tree against its manifest:
    # the manifest must exist, its header must name exactly the expected
    # runtime version (a stale tree from before a RUNTIME_VERSION bump fails
    # here) and carry the verified release-bundle digest, every file entry
    # must exist with a matching digest, and no unlisted runtime file may
    # have appeared. Returns the file entries (relative paths).
    def verify_manifest!(vendor_dir, expected_runtime_version:)
      manifest = File.join(vendor_dir, MANIFEST_NAME)
      unless File.file?(manifest)
        raise "#{vendor_dir}/#{MANIFEST_NAME} missing — run `rake vendor` before building the platform gem"
      end
      headers = {}
      entries = {}
      File.readlines(manifest).each do |line|
        line = line.strip
        next if line.empty?
        case line
        when /\Aruntime_version (\S+)\z/ then headers["runtime_version"] = $1
        when /\Abundle_sha256 (\h{64})\z/ then headers["bundle_sha256"] = $1
        when /\A(\h{64})  (\S.*)\z/ then entries[$2] = $1
        else
          # Fail-closed applies to the manifest itself: an unrecognized line
          # means a format we did not write, not something to skip.
          raise "unrecognized manifest line: #{line.inspect} — re-run `rake vendor`"
        end
      end
      unless headers["runtime_version"]
        raise "vendor manifest lacks a runtime_version header (pre-versioning format) — re-run `rake vendor`"
      end
      unless headers["runtime_version"] == expected_runtime_version
        raise "vendor tree was staged from runtime #{headers["runtime_version"]}, but this build " \
          "expects #{expected_runtime_version} — re-run `rake vendor`"
      end
      unless headers["bundle_sha256"]
        raise "vendor manifest lacks the verified release-bundle digest — re-run `rake vendor`"
      end
      raise "vendor manifest lists no bin/msb" unless entries.key?("bin/msb")
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

    # Post-build verification of the FINISHED gem: extract its payload and
    # re-run the manifest verification on what was actually packaged. Closes
    # the TOCTOU window between gemspec-time verification and RubyGems'
    # subsequent file reads — whatever raced the build, the artifact itself
    # is proven against the manifest it carries.
    def verify_gem_payload!(gem_path, expected_runtime_version:)
      require "rubygems/package"
      Dir.mktmpdir do |tmp|
        Gem::Package.new(gem_path).extract_files(tmp)
        verify_manifest!(File.join(tmp, "vendor"), expected_runtime_version: expected_runtime_version)
      end
    end

    # Serialize vendor mutation and gem packaging on one advisory file lock,
    # so a concurrent `rake vendor` promotion cannot swap the tree while a
    # build is reading it.
    def with_packaging_lock(dir)
      File.open(File.join(dir, LOCK_NAME), File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        yield
      end
    end

    # Run `<path> --version` with a bounded timeout, requiring a real exit
    # status (stdout drained before reaping, like the SDK-side checker).
    # Returns [stdout, Process::Status], [nil, :timeout], or [nil, nil] when
    # the binary cannot be spawned.
    def run_version_probe(path, timeout:)
      out_r, out_w = IO.pipe
      pid = Process.spawn(path, "--version", out: out_w, err: File::NULL)
      out_w.close
      out_w = nil
      output = nil
      status = nil
      begin
        Timeout.timeout(timeout) do
          output = out_r.read
          _, status = Process.waitpid2(pid)
        end
      rescue Timeout::Error
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          # exited between timeout and kill — reap below
        end
        begin
          Process.waitpid(pid)
        rescue Errno::ECHILD
          # already reaped
        end
        return [nil, :timeout]
      end
      [output, status]
    rescue SystemCallError
      [nil, nil]
    ensure
      out_r&.close
      out_w&.close
    end
  end
end
