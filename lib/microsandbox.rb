# frozen_string_literal: true

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
require_relative "microsandbox/agent"
require_relative "microsandbox/ssh"
require_relative "microsandbox/modification"
require_relative "microsandbox/sandbox"

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

    # Download and install the `msb` runtime + `libkrunfw` into
    # `~/.microsandbox` (idempotent).
    #
    # This gem is SDK-only: nothing is provisioned at build/install time. The
    # runtime comes from the companion `microsandbox-rb-binaries` gem when it is
    # installed (see {ensure_runtime!}); otherwise it is fetched into
    # `~/.microsandbox` on first use. Call this explicitly to provision ahead of
    # time (e.g. while baking a container image) so the first {Sandbox.create}
    # doesn't pay the download. Not needed — and not used — when the binaries
    # gem supplies the runtime.
    # @return [nil]
    def install
      Native.install
      nil
    end

    # Customizable install via the core `Setup` builder. Like {install} but with
    # control over where and what to install — mirrors the Node `Setup` builder.
    #
    # @param base_dir [String, nil] install root (default `~/.microsandbox`)
    # @param version [String, nil] pin the runtime version to download
    # @param force [Boolean] re-download even if binaries already exist — the way
    #   to repair a corrupt/incomplete `~/.microsandbox`
    # @param skip_verify [Boolean] skip the post-install verification step
    # @return [nil]
    def setup(base_dir: nil, version: nil, force: false, skip_verify: false)
      opts = {}
      opts["base_dir"] = base_dir.to_s if base_dir
      opts["version"] = version.to_s if version
      opts["force"] = true if force
      opts["skip_verify"] = true if skip_verify
      Native.setup(opts)
      nil
    end

    # @return [Boolean] whether the runtime is installed and resolvable
    def installed?
      Native.installed?
    end

    # Ensure the `msb` runtime + `libkrunfw` are present *and version-matched*,
    # provisioning them on first use if not. Called automatically by
    # {Sandbox.create}/{Sandbox.start} so a freshly installed gem gets a working
    # runtime without a manual {install} step.
    #
    # Runs at most once per process. When the companion `microsandbox-rb-binaries`
    # gem supplies the runtime (it was activated at load time and its `msb` is
    # what the resolver now returns from {runtime_path}), nothing is downloaded
    # or touched in `~/.microsandbox` — the bundled binaries are already the
    # matching version. Opt out of the download by setting
    # `MICROSANDBOX_NO_AUTO_INSTALL` (e.g. air-gapped hosts that provision the
    # runtime out of band); the runtime is then left untouched and a missing or
    # stale one surfaces at the operation itself.
    #
    # NOTE: this delegates to {install} even when {installed?} is already true,
    # rather than short-circuiting on presence. {installed?} (upstream
    # `verify_installation`) only confirms the `msb`/`libkrunfw` files *exist*, not
    # that their version matches the runtime this gem build links. {install} is
    # idempotent and *version-correcting*: it runs a cheap `msb --version` and
    # re-downloads ONLY when the binary is absent or its version differs, then
    # no-ops. A presence-only short-circuit would let a stale `msb` left in
    # `~/.microsandbox` by an older gem pass, then fail every {Sandbox.create} on a
    # host↔guest wire-protocol mismatch (e.g. a `v0.5.8` `msb` rejecting the
    # `--config-fd` flag the `v0.5.10` runtime passes). Keep the {install} call on
    # this path — do not "optimize" it back to skip-when-present.
    # @return [nil]
    def ensure_runtime!
      return if @runtime_ready
      # A cloud backend has no local msb/libkrunfw runtime to provision: skip the
      # presence check and the first-use download entirely. Resolving the kind
      # uses the same lazy env/profile/config ladder every operation already
      # consults, so this adds no work for local hosts (the common case).
      return if default_backend_kind == :cloud
      # The binaries gem won the resolver: its vendored msb (and the libkrunfw
      # beside it) are exactly the version this gem was built for, so there is
      # nothing to verify or download. (If `MSB_PATH` overrides it, the user owns
      # the runtime and we fall through to the existing behaviour.)
      if bundled_runtime_active?
        @runtime_ready = true
        return
      end
      # Opted out: the caller manages the runtime out of band, so don't fetch,
      # verify, or repair it here. Memoize the decision (the env var is stable for
      # the process); the operation resolves `msb` itself and surfaces any problem.
      if auto_install_disabled?
        @runtime_ready = true
        return
      end

      unless installed?
        warn "[microsandbox] runtime (msb + libkrunfw) not found; " \
             "downloading to ~/.microsandbox (set MICROSANDBOX_NO_AUTO_INSTALL to skip, " \
             "or install the microsandbox-rb-binaries gem to ship it with your bundle)..."
      end
      install
      @runtime_ready = true
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
    def runtime_path=(path)
      if @bundled_msb_path && path.to_s != @bundled_msb_path
        warn "[microsandbox] runtime_path= ignored: the microsandbox-rb-binaries gem already " \
             "claimed the set-once SDK slot (#{@bundled_msb_path}); set MSB_PATH to override it"
      end
      Native.set_runtime_msb_path(path.to_s)
    end

    # Override the `libkrunfw` shared-library path (SDK tier of the resolver,
    # below the `MSB_LIBKRUNFW_PATH` environment variable). Process-level and
    # set-once: a second call is silently ignored, and the env var still wins.
    # Mirrors {runtime_path=} for libkrunfw.
    # @param path [String]
    # @return [void]
    def libkrunfw_path=(path)
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
    # @param kind ["local","cloud", Symbol]
    # @param url [String, nil]
    # @param api_key [String, nil]
    # @param profile [String, nil]
    # @yield with the temporary backend installed
    # @return [Object] the block's return value
    def with_backend(kind, url: nil, api_key: nil, profile: nil)
      token = Native.push_default_backend(kind.to_s, url&.to_s, api_key&.to_s, profile&.to_s)
      begin
        yield
      ensure
        Native.pop_default_backend(token)
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
      unless Binaries::RUNTIME_VERSION == RUNTIME_VERSION
        warn "[microsandbox] ignoring microsandbox-rb-binaries #{Binaries::VERSION} " \
             "(runtime #{Binaries::RUNTIME_VERSION}): microsandbox-rb #{VERSION} needs " \
             "runtime #{RUNTIME_VERSION}. Install both gems at the same version; " \
             "falling back to ~/.microsandbox."
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
    rescue => e
      warn "[microsandbox] could not activate microsandbox-rb-binaries: #{e.class}: #{e.message}"
      nil
    end

    # Gems allowed to provide `microsandbox/binaries` (see activate_bundled_runtime!).
    TRUSTED_BINARIES_OWNERS = %w[microsandbox-rb-binaries microsandbox-rb].freeze
    private_constant :TRUSTED_BINARIES_OWNERS

    # Name of the loaded gem whose files define Microsandbox::Binaries, or nil
    # when it came from a bare load path.
    def bundled_runtime_owner
      source = Binaries.method(:msb_path).source_location&.first
      return nil unless source
      spec = Gem.loaded_specs.values.find { |s| source.start_with?(File.join(s.full_gem_path, "")) }
      spec&.name
    end

    # Whether the binaries gem's msb is what the resolver actually returns — i.e.
    # it was activated and nothing higher in the ladder (`MSB_PATH`) overrides it.
    def bundled_runtime_active?
      return false unless @bundled_msb_path
      runtime_path == @bundled_msb_path
    rescue Microsandbox::Error
      false
    end
  end

  send(:activate_bundled_runtime!)
end
