# frozen_string_literal: true

require "monitor"

require_relative "microsandbox/version"

# Load the compiled native extension. Precompiled platform gems stage the
# binary under a major.minor subdirectory (e.g.
# lib/microsandbox/3.4/microsandbox_rb.bundle) — that is the directory
# rake-compiler builds (it matches the `ruby_version` against /(\d+\.\d+)/), NOT
# the API string "3.4.0" that RbConfig::CONFIG["ruby_version"] returns. Use
# RUBY_VERSION's major.minor so the require hits the staged path; fall back to
# the flat path source builds produce.
begin
  abi_version = RUBY_VERSION[/\d+\.\d+/]
  require_relative "microsandbox/#{abi_version}/microsandbox_rb"
rescue LoadError
  require_relative "microsandbox/microsandbox_rb"
end

require_relative "microsandbox/errors"
require_relative "microsandbox/backend_info"
require_relative "microsandbox/runtime_info"
require_relative "microsandbox/exec_output"
require_relative "microsandbox/exec_handle"
require_relative "microsandbox/fs"
require_relative "microsandbox/metrics"
require_relative "microsandbox/log_entry"
require_relative "microsandbox/streams"
require_relative "microsandbox/image"
require_relative "microsandbox/volume"
require_relative "microsandbox/snapshot"
require_relative "microsandbox/patch"
require_relative "microsandbox/root_disk"
require_relative "microsandbox/network"
require_relative "microsandbox/outbound_proxy"
require_relative "microsandbox/agent"
require_relative "microsandbox/ssh"
require_relative "microsandbox/modification"
require_relative "microsandbox/sandbox"
require_relative "microsandbox/storage"

# Microsandbox — lightweight microVM sandboxes for Ruby.
#
# The runtime is embedded directly in the process via a Rust native extension;
# there is no daemon to install and no server to connect to. Creating a sandbox
# spawns a real microVM as a child process.
#
# @example
#   Microsandbox::Sandbox.create("hello", image: "python") do |sb|
#     puts sb.exec("python", ["-c", "print('Hello, World!')"]).stdout
#   end
module Microsandbox
  # Serializes runtime provisioning within this process: {install}, {setup} and
  # the first-use check in {ensure_runtime!}. The installer replaces files in
  # place, so two threads racing through a first `Sandbox.create` must not both
  # run it. A Monitor (re-entrant) because ensure_runtime! calls install.
  RUNTIME_SETUP_LOCK = Monitor.new
  private_constant :RUNTIME_SETUP_LOCK

  class << self
    # @return [String] the gem version
    def version
      VERSION
    end

    # The upstream microsandbox runtime release this gem build embeds (the git
    # `tag` pinned in ext/microsandbox/Cargo.toml). The gem's own {version} is
    # versioned independently of this, so consult this to learn which runtime is
    # wrapped. See the Versioning section of the README for the full map.
    # @return [String] e.g. "v0.5.8"
    def runtime_version
      RUNTIME_VERSION
    end

    # Install the runtime this SDK was built for — `msb` + `libkrunfw` of
    # upstream {RUNTIME_VERSION} — into the runtime home (`MSB_HOME`, default
    # `~/.microsandbox`).
    #
    # This gem is SDK-only: nothing is provisioned at build/install time. The
    # runtime comes from the companion `microsandbox-rb-binaries` gem when it is
    # installed (see {ensure_runtime!}); otherwise it is fetched into the home
    # on first use. Call this explicitly to provision ahead of time (e.g. while
    # baking a container image) so the first {Sandbox.create} doesn't pay the
    # download.
    #
    # Version-aware and idempotent. It checks the home itself — the exact two
    # files the resolver expects there — whatever `MSB_PATH` or a configured
    # path would select instead:
    #
    # - both present and `msb` is exactly {RUNTIME_VERSION}: nothing to do (no
    #   download), unless +force+;
    # - absent: download and install;
    # - present but another version (a pre-0.7 `msb` carries none): replace both;
    # - only one of the two present: raise — the installer never repairs a
    #   partial home; the message names the files to delete.
    #
    # @param force [Boolean] reinstall even when the home is already current
    # @return [nil]
    # @raise [RuntimeIncompleteError] when the home holds only half of the pair
    def install(force: false)
      RUNTIME_SETUP_LOCK.synchronize do
        msb, lib = Native.runtime_home_pair
        case home_runtime_state(msb, lib)
        when :partial then raise RuntimeIncompleteError, partial_home_message(msb, lib)
        when :absent then Native.install_runtime({})
        when :stale then Native.install_runtime({"force" => true})
        when :current then Native.install_runtime({"force" => true}) if force
        end
      end
      nil
    end

    # Customizable install via upstream's installer. Like {install} but with
    # control over where and what to install — mirrors the Node `Setup` builder.
    # Presence-only: a complete pair already in the target home is kept unless
    # +force+, whatever its version.
    #
    # @param base_dir [String, nil] install root (default `~/.microsandbox`)
    # @param version [String, nil] the runtime release to download. Runtime
    #   v0.7 launches only an `msb` of exactly {RUNTIME_VERSION}: any other
    #   version is refused at every local sandbox start, so this warns.
    # @param force [Boolean] re-download even if binaries already exist — the way
    #   to repair a corrupt `~/.microsandbox`
    # @param skip_verify [Boolean] skip the post-install verification step
    # @return [nil]
    def setup(base_dir: nil, version: nil, force: false, skip_verify: false)
      opts = {}
      opts["base_dir"] = base_dir.to_s if base_dir
      if version
        opts["version"] = version.to_s
        unless version.to_s.delete_prefix("v") == sdk_runtime_version
          warn "[microsandbox] setup(version: #{version.to_s.inspect}): this SDK launches only runtime " \
               "#{sdk_runtime_version}; a #{version.to_s.delete_prefix("v")} runtime will be refused " \
               "at every local sandbox start"
        end
      end
      opts["force"] = true if force
      opts["skip_verify"] = true if skip_verify
      RUNTIME_SETUP_LOCK.synchronize { Native.setup(opts) }
      nil
    end

    # Whether a complete `msb` + `libkrunfw` pair resolves from any source the
    # local backend would use (`MSB_PATH`, the binaries gem, configured paths,
    # the runtime home). Presence only: says nothing about the version — see
    # {runtime_info} and {RuntimeInfo#matches_sdk?}.
    # @return [Boolean]
    def installed?
      Native.installed?
    end

    # The runtime pair local sandboxes would launch with, and where it came
    # from. Reads files and the environment only (nothing is downloaded,
    # created or run); independent of the selected backend.
    # @return [RuntimeInfo]
    # @raise [RuntimeNotInstalledError] when no pair resolves from any source
    # @raise [RuntimeIncompleteError] when the selected source is partial or
    #   unpaired (e.g. `MSB_PATH` with no `libkrunfw` beside it)
    def runtime_info
      data = Native.runtime_info
      RuntimeInfo.new(data.merge("origin" => classify_runtime_origin(data)))
    end

    # Make sure local sandboxes can start: the runtime pair resolves and its
    # `msb` is exactly the version this SDK was built for (runtime v0.7 refuses
    # every other one at launch). Called automatically by {Sandbox.create},
    # {Sandbox.start} and the other calls that boot a microVM, so a freshly
    # installed gem gets a working runtime without a manual {install} step.
    #
    # Runs at most once per process (successful outcomes are memoized):
    #
    # - cloud backend, or the binaries gem's runtime is the one selected:
    #   nothing to do;
    # - `MICROSANDBOX_NO_AUTO_INSTALL` set: never downloads or writes. A
    #   mismatched runtime is reported with a warning; a missing or partial one
    #   is left for the operation itself to raise;
    # - nothing resolves: warn, then {install} into the runtime home;
    # - the runtime home's own `msb` is another version: warn, then
    #   `install(force: true)` replaces the pair;
    # - another source (`MSB_PATH`, configured paths) is another version:
    #   never touched — warn that every local start will be refused;
    # - a partial pair: raise with the files to delete or the variable to set.
    #
    # The local backend reads its runtime configuration (`MSB_HOME`,
    # `MSB_PATH`, `MSB_LIBKRUNFW_PATH`, the config file) once, when it is
    # first used; if it has changed since, this raises {InvalidConfigError}
    # before checking or installing anything.
    # @return [nil]
    # @raise [RuntimeIncompleteError] for a partial runtime (unless opted out)
    # @raise [InvalidConfigError] when the runtime configuration changed after
    #   the local backend was created
    def ensure_runtime!
      return if @runtime_ready
      RUNTIME_SETUP_LOCK.synchronize do
        # Re-check under the lock: another thread may have finished meanwhile.
        return if @runtime_ready
        # A cloud backend has no local msb/libkrunfw runtime to provision.
        return if default_backend_kind == :cloud
        # The local backend captured its runtime configuration when it was
        # built (this builds it if nothing has yet). Refuse when the current
        # configuration has moved away from it — before anything is installed
        # or memoized. Everything below then reads that captured
        # configuration only (`Native.backend_*`): the runtime it selects, its
        # home pair and the install target, so a change to the environment
        # while bootstrap runs cannot redirect the decision or the write.
        Native.verify_backend_runtime_config
        home_msb, = Native.backend_runtime_home_pair
        # The binaries gem won the resolver: its vendored pair is exactly the
        # version this gem was built for, so there is nothing to check.
        if bundled_runtime_active?
          @runtime_ready = true
          return
        end
        info = bootstrap_runtime_info
        return if @runtime_ready # opted out with an incomplete runtime
        if auto_install_disabled?
          # Opted out: the caller manages the runtime out of band. Never write;
          # a missing runtime surfaces at the operation itself.
          warn_runtime_mismatch(info) if info && !info.matches_sdk?
        elsif info.nil?
          warn "[microsandbox] runtime (msb + libkrunfw) not found; " \
               "downloading runtime #{sdk_runtime_version} to #{File.dirname(home_msb, 2)} " \
               "(set MICROSANDBOX_NO_AUTO_INSTALL to skip, or install the microsandbox-rb-binaries gem " \
               "to ship it with your bundle)..."
          bootstrap_install(home_msb)
        elsif !info.matches_sdk?
          if replaceable_home_runtime?(info, home_msb)
            warn "[microsandbox] runtime #{describe_runtime_version(info)} in #{File.dirname(info.msb_path, 2)} " \
                 "is not the #{sdk_runtime_version} this SDK launches; replacing it " \
                 "(set MICROSANDBOX_NO_AUTO_INSTALL to keep it)..."
            bootstrap_install(home_msb, force: true)
          else
            warn_runtime_mismatch(info)
          end
        end
        @runtime_ready = true
      end
      nil
    end

    # @return [String] the resolved path to the `msb` runtime binary
    def runtime_path
      Native.resolved_msb_path
    end

    # Override the `msb` runtime path (highest-priority SDK tier of the
    # resolver, below only the `MSB_PATH` environment variable). Process-level
    # and set-once: a second call is silently ignored, and the `MSB_PATH`
    # environment variable still wins. Mirrors {libkrunfw_path=}.
    #
    # The companion `microsandbox-rb-binaries` gem claims this same slot when
    # `require "microsandbox"` activates it, so with that gem installed this
    # setter is a no-op — use `MSB_PATH` to override a bundled runtime.
    # @param path [String]
    # @return [void]
    # @raise [ArgumentError] for nil or an empty path (the slot cannot be cleared)
    def runtime_path=(path)
      require_runtime_path!(:runtime_path=, path)
      if @bundled_msb_path && path.to_s != @bundled_msb_path
        warn "[microsandbox] runtime_path= ignored: the microsandbox-rb-binaries gem already " \
             "claimed the set-once SDK slot (#{@bundled_msb_path}); set MSB_PATH to override it"
      end
      Native.set_runtime_msb_path(path.to_s)
    end

    # Override the `libkrunfw` shared-library path (SDK tier of the resolver,
    # below the `MSB_LIBKRUNFW_PATH` environment variable). Process-level and
    # set-once: a second call is silently ignored, and the env var still wins.
    # Mirrors {runtime_path=} for libkrunfw. The companion
    # `microsandbox-rb-binaries` gem claims this slot too (unless `MSB_PATH` is
    # set when `microsandbox` is required), which makes this a no-op.
    # @param path [String]
    # @return [void]
    # @raise [ArgumentError] for nil or an empty path (the slot cannot be cleared)
    def libkrunfw_path=(path)
      require_runtime_path!(:libkrunfw_path=, path)
      if @bundled_libkrunfw_claimed && path.to_s != @bundled_libkrunfw_path
        warn "[microsandbox] libkrunfw_path= ignored: the microsandbox-rb-binaries gem already " \
             "claimed the set-once SDK slot (#{@bundled_libkrunfw_path}); set MSB_PATH (and " \
             "MSB_LIBKRUNFW_PATH) to override it"
      end
      Native.set_runtime_libkrunfw_path(path.to_s)
    end

    # Install a process-wide default backend (v0.5.8 backend routing). Without a
    # call to this, operations use a local libkrun backend; the env/profile
    # ladder (`MSB_BACKEND` → `MSB_PROFILE` → `~/.microsandbox/config.json`) is
    # resolved lazily on first use. Since runtime v0.6.9 a bare `MSB_API_KEY`
    # no longer selects the cloud — cloud intent must be explicit via
    # `MSB_BACKEND=cloud` (paired with `MSB_API_URL`/`MSB_API_KEY`), a cloud
    # profile, or this method; invalid cloud config raises
    # {InvalidConfigError} instead of falling back to local. Call once at
    # startup, before any sandbox operations.
    #
    # @param kind ["local","cloud", Symbol] backend kind
    # @param url [String, nil] cloud control-plane URL (cloud, unless `profile:`)
    # @param api_key [String, nil] cloud API key (cloud, unless `profile:`)
    # @param profile [String, nil] named profile from `~/.microsandbox/config.json`
    # @return [void]
    def set_default_backend(kind, url: nil, api_key: nil, profile: nil)
      Native.set_default_backend(kind.to_s, url&.to_s, api_key&.to_s, profile&.to_s)
    end

    # Run the given block with a temporary default backend, restoring the
    # previous one afterward (even on error). NOTE: the swap is process-wide
    # while the block runs, not fiber/thread-local — concurrent threads observe
    # the temporary backend. It is also NOT safe to call from multiple threads
    # at once: two interleaved `with_backend` calls can restore each other's
    # saved backend out of order and leave a temporary backend installed
    # permanently. Use it only when no other thread is changing the backend, and
    # avoid calling {set_default_backend} inside the block (the restore on exit
    # would overwrite that change). Mirrors the official SDKs' scoped-backend helper.
    #
    # The restore can fail in one situation: the previous backend belonged to a
    # parent process (the block is left in a child forked while it was running,
    # or it is a forked child's first use of the SDK) and cannot be chosen
    # again there — it came from the environment or config file, which no
    # longer resolve. The block's temporary selection then stays in effect. If
    # the block itself raised, its exception is the one that propagates and the
    # restore failure is only warned about; otherwise the restore failure is
    # raised.
    #
    # @param kind ["local","cloud", Symbol]
    # @param url [String, nil]
    # @param api_key [String, nil]
    # @param profile [String, nil]
    # @yield with the temporary backend installed
    # @return [Object] the block's return value
    def with_backend(kind, url: nil, api_key: nil, profile: nil)
      token = Native.push_default_backend(kind.to_s, url&.to_s, api_key&.to_s, profile&.to_s)
      raised = false
      begin
        yield
      rescue Exception # standard:disable Lint/RescueException -- only noted, re-raised at once
        raised = true
        raise
      ensure
        begin
          Native.pop_default_backend(token)
        rescue Microsandbox::Error => e
          # Never let the restore failure replace what the block raised.
          raise unless raised
          warn "microsandbox: with_backend could not restore the previous backend: #{e.message}"
        end
      end
    end

    # @return [Symbol] the active default backend kind, :local or :cloud.
    #   The first call resolves the env/profile/config ladder.
    def default_backend_kind
      Native.default_backend_kind.to_sym
    end

    # Secret-safe description of the active default backend (runtime v0.6.9).
    # Like {default_backend_kind}, the first call freezes ambient env/profile
    # resolution for the process. The API key is never included.
    # @return [BackendInfo]
    def default_backend_info
      BackendInfo.new(Native.default_backend_info)
    end

    # Latest resource-usage snapshot for every running sandbox, keyed by name.
    # Mirrors the official `all_sandbox_metrics`/`allSandboxMetrics` helpers.
    # @return [Hash{String => Metrics}]
    def all_sandbox_metrics
      Native.all_sandbox_metrics.transform_values { |m| Metrics.new(m) }
    end

    # Coerce write data to a binary-safe String, or raise. Centralizes the
    # contract every `#write` shares (FS/SftpClient/VolumeFs/ExecStdin/
    # FsWriteSink): accept a String and reject anything else loudly, instead of
    # silently writing its `to_s` form (e.g. a StringIO's inspect or "42").
    # @api private
    # @param data [Object]
    # @return [String]
    # @raise [TypeError] unless +data+ is a String
    def coerce_write_bytes(data)
      String.try_convert(data) or
        raise TypeError, "data must be a String (got #{data.class})"
    end

    # A Time for an epoch-milliseconds Integer from the native layer, or nil.
    # Integer arithmetic on purpose: `Time.at(ms / 1000.0)` goes through a
    # Float and lands one millisecond low for about half of all timestamps.
    # @api private
    # @param ms [Integer, nil]
    # @return [Time, nil]
    def time_from_ms(ms)
      ms && Time.at(ms.div(1000), ms % 1000, :millisecond)
    end

    # Run the block, then close +resource+ — the shared tail of the block forms
    # that own a resource whose close can fail (a write sink flushes on close).
    # If the block raised, its exception is the one the caller needs: a failure
    # from the close that follows is dropped instead of replacing it. If the
    # block finished (or left via break/throw), a close failure propagates.
    # @api private
    def close_after(resource)
      raised = false
      yield
    rescue Exception # standard:disable Lint/RescueException -- re-raised unchanged
      raised = true
      raise
    ensure
      begin
        resource.close
      rescue
        raise unless raised
      end
    end

    private

    # Auto-provisioning is on by default; any non-empty, non-"0"/"false" value
    # of MICROSANDBOX_NO_AUTO_INSTALL disables it.
    def auto_install_disabled?
      v = ENV["MICROSANDBOX_NO_AUTO_INSTALL"]
      !v.nil? && !v.empty? && !%w[0 false no].include?(v.downcase)
    end

    # Wire the companion `microsandbox-rb-binaries` gem into the core resolver.
    # Runs once, at `require "microsandbox"` time (like the Node SDK, which pushes
    # its platform package's msb into the same set-once SDK slot at module load)
    # so every entry point that spawns msb — not just {Sandbox.create} — sees it.
    #
    # The gem is optional and has no dependency edge to this one (cloud-only
    # users skip the ~50 MB download; RubyGems has no optional dependencies), so
    # discovery is by require: absent → nothing happens and the resolver's lower
    # tiers (`~/.microsandbox`, then `PATH`) plus the first-use download take
    # over. Present but built for a different upstream runtime → warn and skip
    # it rather than hand the core a mismatched msb (a stale runtime passes an
    # exists-check and then fails every create on a wire-protocol mismatch).
    # Only `MSB_PATH` (env) outranks the slot claimed here.
    #
    # Never raises: a broken companion gem must not take `require "microsandbox"`
    # down with it.
    # @return [String, nil] the activated msb path
    def activate_bundled_runtime!
      @bundled_msb_path = nil
      @bundled_libkrunfw_path = nil
      @bundled_libkrunfw_claimed = false
      begin
        # Pin the lockstep version when RubyGems (not Bundler) picks the gem, so
        # a newer/older companion left around doesn't get activated over the
        # matching one. Under Bundler the Gemfile already decides; a companion
        # that isn't in the bundle raises here and `require` then fails below.
        gem "microsandbox-rb-binaries", "= #{VERSION}"
      rescue Gem::LoadError
        # Not installed at this version — `require` settles it.
      end
      begin
        require "microsandbox/binaries"
      rescue LoadError
        return nil
      end
      # A bare require activates the newest gem of ANY name that ships this
      # feature path; only accept the companion gem itself, this gem's own tree
      # (a source checkout, where Bundler's path gem spans the whole repo and so
      # owns binaries/lib too), or a plain load path (RUBYLIB/-I) no gem owns.
      owner = bundled_runtime_owner
      if owner && !TRUSTED_BINARIES_OWNERS.include?(owner)
        warn "[microsandbox] ignoring microsandbox/binaries provided by the #{owner} gem " \
             "(only microsandbox-rb-binaries is trusted for the bundled runtime)"
        return nil
      end
      # Lockstep gate on BOTH constants. The runtime tag is what the wire
      # protocol depends on; the gem version is the documented contract
      # ("install both at the same version") and also covers this file's own
      # API/packaging — the `gem "…", "= VERSION"` pin above is best-effort (it
      # raises under Bundler whenever the bundle picked any other version, and
      # that is swallowed), so it cannot be what enforces it.
      unless Binaries::VERSION == VERSION && Binaries::RUNTIME_VERSION == RUNTIME_VERSION
        warn "[microsandbox] ignoring microsandbox-rb-binaries #{Binaries::VERSION} " \
             "(runtime #{Binaries::RUNTIME_VERSION}): microsandbox-rb #{VERSION} " \
             "(runtime #{RUNTIME_VERSION}) needs the companion gem at the same version. " \
             "Install both gems at the same version; falling back to ~/.microsandbox."
        return nil
      end
      msb = Binaries.msb_path
      unless msb && Binaries.libkrunfw_path
        warn "[microsandbox] microsandbox-rb-binaries #{Binaries::VERSION} is installed but " \
             "carries no runtime under #{Binaries.root}; falling back to ~/.microsandbox."
        return nil
      end
      Native.set_runtime_msb_path(msb)
      @bundled_msb_path = msb
      @bundled_libkrunfw_path = Binaries.libkrunfw_path
      # Pair the library explicitly too (msb first: a library slot with no
      # msb slot would pair a home msb with this library). Not when `MSB_PATH`
      # is set: the resolver takes the library slot over the one next to an
      # `MSB_PATH` runtime, which would pair that runtime with this library.
      unless ENV.key?("MSB_PATH")
        Native.set_runtime_libkrunfw_path(@bundled_libkrunfw_path)
        @bundled_libkrunfw_claimed = true
      end
      msb
    rescue StandardError, ScriptError => e
      # ScriptError too: a corrupt or newer-syntax binaries.rb raises
      # SyntaxError (not a StandardError) out of `require`, and the optional
      # companion must never take `require "microsandbox"` down with it.
      warn "[microsandbox] could not activate microsandbox-rb-binaries: #{e.class}: #{e.message}"
      nil
    end

    # Gems allowed to provide `microsandbox/binaries` (see activate_bundled_runtime!).
    TRUSTED_BINARIES_OWNERS = %w[microsandbox-rb-binaries microsandbox-rb].freeze
    private_constant :TRUSTED_BINARIES_OWNERS

    # Name of the loaded gem whose files define Microsandbox::Binaries, or nil
    # when it came from a bare load path. Gem roots can nest — a host project
    # that is itself a gem, with its bundle installed under the project
    # directory, is a prefix of every gem in that bundle — so the owner is the
    # gem with the LONGEST matching root, not whichever one is listed first.
    def bundled_runtime_owner
      source = Binaries.method(:msb_path).source_location&.first
      return nil unless source
      roots = Gem.loaded_specs.values.select { |s| source.start_with?(File.join(s.full_gem_path, "")) }
      roots.max_by { |s| s.full_gem_path.length }&.name
    end

    # The runtime path slots are set-once in the core and have no "unset": nil
    # or "" would be stored as an empty path for the rest of the process.
    def require_runtime_path!(setter, path)
      return unless path.nil? || path.to_s.empty?
      raise ArgumentError, "#{setter} needs a non-empty path (the slot is set-once and cannot be cleared)"
    end

    # Whether the binaries gem's pair is what the resolver actually returns —
    # it was activated, nothing higher in the ladder (`MSB_PATH`) overrides it,
    # and the library paired with its msb is its own.
    def bundled_runtime_active?
      return false unless @bundled_msb_path
      info = backend_runtime_info
      info.origin == :sdk_package && same_path?(info.libkrunfw_path, @bundled_libkrunfw_path)
    rescue Microsandbox::Error
      false
    end

    # Runtime v0.7.14 layers `MSB_PATH` and the SDK path slots into the
    # configuration before it resolves, so it reports both as `configuration`.
    # Tell them apart by the resolved msb, in the precedence the layering uses
    # (the environment wins over the slot). Every other origin is passed
    # through untouched — `home` above all, which the forced reinstall keys on.
    def classify_runtime_origin(data)
      origin = data["origin"]
      return origin unless origin == "configuration"
      msb = data["msb_path"]
      # `key?`, not non-empty: the core reads an empty MSB_PATH as set.
      return "environment" if ENV.key?("MSB_PATH") && same_path?(msb, ENV["MSB_PATH"])
      return "sdk_package" if @bundled_msb_path && same_path?(msb, @bundled_msb_path)
      origin
    end

    # Whether two runtime paths name the same file: equal once expanded (the
    # core makes a relative MSB_PATH absolute against the working directory),
    # or with the same real path.
    def same_path?(a, b)
      return false if a.nil? || b.nil? || a.to_s.empty? || b.to_s.empty?
      return true if File.expand_path(a) == File.expand_path(b)
      File.realpath(a) == File.realpath(b)
    rescue SystemCallError
      false
    end

    # "0.7.14", the runtime version this SDK launches.
    def sdk_runtime_version = RUNTIME_VERSION.delete_prefix("v")

    # The state of the runtime home itself — the exact two files the resolver
    # expects there (no glob: an unrelated `libkrunfw.backup` is not the
    # library) — whatever a higher-priority source would select instead.
    def home_runtime_state(msb, lib)
      has_msb = File.file?(msb)
      has_lib = File.file?(lib)
      return :absent unless has_msb || has_lib
      return :partial unless has_msb && has_lib
      (home_msb_version(msb) == sdk_runtime_version) ? :current : :stale
    end

    # An unreadable home msb counts as stale: the installer replaces it.
    def home_msb_version(msb)
      Native.msb_version(msb)
    rescue Microsandbox::Error
      nil
    end

    def partial_home_message(msb, lib)
      present, missing = [msb, lib].partition { |path| File.file?(path) }
      "partial runtime installation in #{File.dirname(msb, 2)}: found #{present.join(", ")} " \
        "but not #{missing.join(", ")}. The installer never repairs a partial home; " \
        "delete #{msb} and #{lib} (whichever exist) and retry"
    end

    # {runtime_info} of the local backend's captured configuration — the pair
    # `create` launches — for ensure_runtime!.
    def backend_runtime_info
      data = Native.backend_runtime_info
      RuntimeInfo.new(data.merge("origin" => classify_runtime_origin(data)))
    end

    # ensure_runtime!'s install: into the captured configuration's home
    # (`home_msb` is the pair the decision was made for), never one read
    # afresh. {install} stays backend-independent.
    def bootstrap_install(home_msb, force: false)
      Native.install_backend_runtime(home_msb, force ? {"force" => true} : {})
    end

    # backend_runtime_info for ensure_runtime!: nil when nothing resolves. A
    # partial runtime raises with directions — unless opted out, when the
    # operation is left to raise it (and the process is marked ready).
    def bootstrap_runtime_info
      backend_runtime_info
    rescue RuntimeNotInstalledError
      nil
    rescue RuntimeIncompleteError => e
      if auto_install_disabled?
        @runtime_ready = true
        return nil
      end
      # The error comes from the first source the resolver consulted: the
      # environment when it is set, otherwise (no configured paths) the home.
      hint = runtime_env_hint || begin
        msb, lib = Native.backend_runtime_home_pair
        partial_home_message(msb, lib) if home_runtime_state(msb, lib) == :partial
      end
      raise unless hint
      raise RuntimeIncompleteError, "#{e.message} — #{hint}"
    end

    def runtime_env_hint
      return nil unless ENV.key?("MSB_PATH") || ENV.key?("MSB_LIBKRUNFW_PATH")
      "MSB_PATH needs libkrunfw beside it (in its directory or ../lib) or MSB_LIBKRUNFW_PATH " \
        "naming it; MSB_LIBKRUNFW_PATH alone is not enough"
    end

    # The forced reinstall replaces files in the user's home, so only when the
    # resolved pair provably IS the home pair.
    def replaceable_home_runtime?(info, home_msb)
      info.origin == :home && same_path?(info.msb_path, home_msb)
    end

    def describe_runtime_version(info)
      info.version || "with no embedded version (pre-0.7 msb or a wrapper script)"
    end

    # The one mismatch warning (4c / 7): a runtime this SDK did not install
    # and will not touch.
    def warn_runtime_mismatch(info)
      warn "[microsandbox] runtime #{info.version || "no embedded version (pre-0.7 msb or a wrapper script)"} " \
           "at #{info.msb_path} ≠ SDK #{sdk_runtime_version}: every local sandbox start will be refused"
    end
  end

  send(:activate_bundled_runtime!)
end
