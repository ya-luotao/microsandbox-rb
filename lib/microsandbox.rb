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
    # When the gem is built from source, the native extension provisions the
    # runtime at build time, so this is usually a no-op. Precompiled platform
    # gems (which skip the local Rust build) do NOT provision it that way, so the
    # runtime is fetched on first use — see {ensure_runtime!}. Call this
    # explicitly to provision ahead of time (e.g. while baking a container
    # image) so the first {Sandbox.create} doesn't pay the download.
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
    # {Sandbox.create}/{Sandbox.start} so precompiled-gem users (who never ran the
    # source build) get a working runtime without a manual {install} step.
    #
    # Runs at most once per process. Opt out by setting
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
      claim_binaries_gem_slots!
      # A binaries companion gem IS the provisioning: its vendored runtime was
      # sha256-verified at gem build time and version-matched by lockstep
      # versioning, so the first-use download is unnecessary — skip it even when
      # auto-install is otherwise enabled. The per-tier version check below still
      # runs against whatever the resolver actually picks (an `MSB_PATH` env
      # override outranks the gem and may be stale).
      if binaries_gem_msb_path
        verify_runtime_version!
        @runtime_ready = true
        return
      end
      # Opted out: the caller manages the runtime out of band, so don't fetch,
      # verify, or repair it here. Memoize the decision (the env var is stable for
      # the process); the operation resolves `msb` itself and surfaces any problem.
      # The version check still runs (warn-only) so a stale out-of-band runtime is
      # at least diagnosed, if not repaired.
      if auto_install_disabled?
        verify_runtime_version!
        @runtime_ready = true
        return
      end

      unless installed?
        warn "[microsandbox] runtime (msb + libkrunfw) not found; " \
             "downloading to ~/.microsandbox (set MICROSANDBOX_NO_AUTO_INSTALL to skip)..."
      end
      install
      # {install} version-corrects `~/.microsandbox`, but the resolver may pick a
      # different tier entirely (`MSB_PATH`, a set-once override, PATH) — verify
      # the binary that will actually run, not the one that was just installed.
      verify_runtime_version!
      @runtime_ready = true
      nil
    end

    # @return [String] the resolved path to the `msb` runtime binary
    def runtime_path
      # Claim the binaries-gem tier first so a bare getter (called before any
      # sandbox operation ran ensure_runtime!) reports the same path an
      # operation would resolve.
      claim_binaries_gem_slots!
      Native.resolved_msb_path
    end

    # Override the `msb` runtime path (highest-priority SDK tier of the
    # resolver, below only the `MSB_PATH` environment variable). Process-level
    # and set-once: a second call is silently ignored, and the `MSB_PATH`
    # environment variable still wins. Mirrors {libkrunfw_path=}.
    # @param path [String]
    # @return [void]
    def runtime_path=(path)
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
    # ladder (`MSB_BACKEND`, `MSB_API_URL`+`MSB_API_KEY`, `MSB_PROFILE`,
    # `~/.microsandbox/config.json`) is resolved lazily on first use. Call once
    # at startup, before any sandbox operations.
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

    # Feed the binaries companion gem's vendored runtime into the resolver
    # (prototype of the two-gem split from upstream #1305). The core resolver
    # ladder is `MSB_PATH` env → SDK slot → config → `~/.microsandbox` → PATH,
    # and lives inside the pinned core crate — there is no dedicated
    # "language-package binary" tier to target, but the SDK slot's own docs name
    # exactly this use ("FFI bindings that ship a binary inside their language
    # package"), so the gem tier piggybacks on it. The slot is a set-once
    # OnceLock, which yields the intended precedence for free: a user's
    # startup-time {runtime_path=} call lands first and this claim becomes a
    # silent no-op, while `MSB_PATH` outranks the slot entirely. Net order:
    # env > user set-once > binaries gem > `~/.microsandbox` > PATH.
    #
    # Known edge of sharing the slot: once this claims it (first sandbox use or
    # first {runtime_path} read), a *later* {runtime_path=} call is silently
    # ignored — previously it would still have taken effect. Setting the
    # override after the runtime resolved was already unsupported ("call once
    # at startup"); a real fix needs a dedicated tier in the core resolver.
    def claim_binaries_gem_slots!
      return if @binaries_gem_claimed
      @binaries_gem_claimed = true
      msb = binaries_gem_msb_path
      return unless msb
      Native.set_runtime_msb_path(msb)
      libkrunfw = binaries_gem_libkrunfw_path
      Native.set_runtime_libkrunfw_path(libkrunfw) if libkrunfw
      nil
    end

    # Path to the vendored `msb` from the `microsandbox-rb-binaries` companion
    # gem, or nil when the gem is absent (not installed) or is the empty
    # ruby-platform fallback build (installed for Gemfile portability on
    # platforms with no prebuilt bundle, ships no binaries, returns nil).
    def binaries_gem_msb_path
      require "microsandbox_rb_binaries"
      MicrosandboxRbBinaries.msb_path
    rescue LoadError
      nil
    end

    # Companion-gem libkrunfw, mirroring {binaries_gem_msb_path}. The core
    # ladder would also find it as `../lib/` relative to the resolved `msb`
    # (the gem vendors `vendor/{bin,lib}` in the installed layout), but claim
    # the explicit slot rather than rely on that layout coupling.
    def binaries_gem_libkrunfw_path
      require "microsandbox_rb_binaries"
      MicrosandboxRbBinaries.libkrunfw_path
    rescue LoadError
      nil
    end

    # Warn-only check that the `msb` the resolver actually picked matches the
    # runtime version this gem build embeds ({RUNTIME_VERSION}). Presence is not
    # correctness: any tier (`MSB_PATH`, a set-once override, the binaries gem,
    # a stale `~/.microsandbox`, PATH) can resolve a version-mismatched binary,
    # and the failure it causes downstream — a host↔guest wire-protocol error at
    # {Sandbox.create} — does not name the real cause. This runs once per
    # process (from {ensure_runtime!}) and deliberately warns instead of
    # raising: a mismatched runtime often still works across patch releases,
    # and hard-failing would break users the old behavior tolerated.
    def verify_runtime_version!
      path = begin
        Native.resolved_msb_path
      rescue => e
        # Nothing resolved at all (no runtime anywhere). Not this check's error
        # to raise — the operation that needs msb surfaces it with context.
        warn "[microsandbox] could not resolve an msb runtime binary: #{e.message}"
        return
      end
      expected = RUNTIME_VERSION.delete_prefix("v")
      output = begin
        IO.popen([path, "--version"], err: File::NULL, &:read)
      rescue SystemCallError
        nil
      end
      actual = output&.[](/\bmsb\s+(\S+)/, 1)
      if actual.nil?
        warn "[microsandbox] could not verify the msb runtime at #{path} " \
             "(`msb --version` failed or printed unrecognized output); " \
             "this gem embeds runtime #{expected}"
      elsif actual != expected
        warn "[microsandbox] runtime version mismatch: msb at #{path} is #{actual}, " \
             "but this gem embeds runtime #{expected} — sandbox operations may fail " \
             "on a host/guest protocol mismatch. Align the runtime with the gem, or " \
             "remove the override that selected it."
      end
      nil
    end
  end
end
