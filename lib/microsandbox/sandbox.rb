# frozen_string_literal: true

require "json"

module Microsandbox
  # A controllable handle to a sandbox, returned by {Sandbox.get}, {Sandbox.list},
  # and {Sandbox.list_with}. Carries a metadata snapshot (captured when fetched)
  # plus the fine-grained lifecycle surface — `stop_with_timeout`, `request_stop`,
  # `request_kill`, `request_drain`, `wait_until_stopped` — that mirrors the
  # official SDKs' `SandboxHandle`. (The live {Sandbox} from {Sandbox.create}/
  # {Sandbox.start} carries only the high-level `stop`/`kill`/`drain`/`wait`.)
  #
  # As of v0.5.8 this replaces the old read-only `SandboxInfo` (kept as a
  # deprecated constant alias); `#status` here is a synchronous snapshot.
  class SandboxHandle
    def initialize(native)
      @native = native
    end

    # @return [String]
    def name = @native.name

    # @return [Symbol] :created, :starting, :running, :draining, :paused,
    #   :stopped, or :crashed (a snapshot, captured when this handle was fetched)
    def status = @native.status.to_sym

    # Whether the fetch-time {#status} snapshot is `:running` / `:stopped`.
    # Like {#status}, these do NOT refresh: to observe a state change after
    # {#request_stop}/{#request_kill}/{#request_drain}, use {#wait_until_stopped}
    # or re-fetch the handle with {Sandbox.get}.
    def running? = status == :running
    def stopped? = status == :stopped

    # @return [Time, nil]
    def created_at
      ms = @native.created_at_ms
      ms && Time.at(ms / 1000.0)
    end

    # @return [Time, nil]
    def updated_at
      ms = @native.updated_at_ms
      ms && Time.at(ms / 1000.0)
    end

    # Gracefully stop the sandbox (SIGTERM→SIGKILL escalation, 10s default).
    # @return [nil]
    def stop
      @native.stop
      nil
    end

    # Gracefully stop with a custom escalation timeout.
    # @param timeout [Numeric] seconds to wait before escalating to SIGKILL
    # @return [nil]
    def stop_with_timeout(timeout)
      @native.stop_with_timeout(Sandbox.send(:coerce_duration, timeout, "timeout"))
      nil
    end

    # Force-kill the sandbox (SIGKILL).
    # @return [nil]
    def kill
      @native.kill
      nil
    end

    # Force-kill, waiting up to `timeout` seconds for the process to disappear.
    # @param timeout [Numeric]
    # @return [nil]
    def kill_with_timeout(timeout)
      @native.kill_with_timeout(Sandbox.send(:coerce_duration, timeout, "timeout"))
      nil
    end

    # Send the graceful-shutdown request and return immediately, without waiting.
    # Pair with {#wait_until_stopped}.
    # @return [nil]
    def request_stop
      @native.request_stop
      nil
    end

    # Send the force-kill request and return immediately, without waiting.
    # @return [nil]
    def request_kill
      @native.request_kill
      nil
    end

    # Request a graceful drain (SIGUSR1) and return immediately, without waiting.
    # @return [nil]
    def request_drain
      @native.request_drain
      nil
    end

    # Block until the sandbox is observed in a terminal (non-running) state.
    # @return [SandboxStopResult]
    def wait_until_stopped
      SandboxStopResult.new(@native.wait_until_stopped)
    end

    # The sandbox's stored configuration as a raw JSON string (synchronous — the
    # handle already carries it, no runtime round-trip). Mirrors the Python/Node
    # `config_json`.
    # @return [String]
    def config_json
      @native.config_json
    end

    # The sandbox's stored configuration, parsed into a Hash (image, cpus,
    # memory, mounts, …). Mirrors the Python/Node `config`.
    # @return [Hash]
    def config
      JSON.parse(@native.config_json)
    end

    # Snapshot this (stopped) sandbox under a bare name, resolved under the
    # snapshots dir. Convenience equivalent of
    # `Snapshot.create(name, name: <snapshot-name>)` addressed by this handle.
    # @param name [String] destination snapshot name
    # @return [SnapshotInfo]
    def snapshot(name)
      SnapshotInfo.new(@native.snapshot(name.to_s))
    end

    # Snapshot this (stopped) sandbox to an explicit filesystem path.
    # @param path [String] destination directory
    # @return [SnapshotInfo]
    def snapshot_to(path)
      SnapshotInfo.new(@native.snapshot_to(path.to_s))
    end

    def inspect
      "#<Microsandbox::SandboxHandle name=#{name.inspect} status=#{status}>"
    end
  end

  # @deprecated since v0.5.8. {Sandbox.get}/{Sandbox.list} now return a
  #   controllable {SandboxHandle}; this constant remains as an alias so code
  #   that referenced the old read-only metadata type by name (e.g. `is_a?`
  #   checks) still resolves. Note it is now the same class as {SandboxHandle},
  #   whose constructor takes a native handle, not the metadata Hash the old
  #   `SandboxInfo.new` accepted — construct via {Sandbox.get}/{Sandbox.list}.
  SandboxInfo = SandboxHandle

  # The terminal observation of a stopped sandbox, returned by
  # {SandboxHandle#wait_until_stopped}. Mirrors the official SDKs' `SandboxStopResult`.
  class SandboxStopResult
    # @return [String]
    attr_reader :name
    # @return [Symbol] :running, :draining, :paused, :stopped, or :crashed
    attr_reader :status
    # @return [Integer, nil] process exit code, when observed from an owned child
    attr_reader :exit_code
    # @return [Integer, nil] terminating signal, when observed from an owned child
    attr_reader :signal
    # @return [String, nil] human description of the observation source
    attr_reader :source

    def initialize(data)
      @name = data["name"]
      @status = data["status"].to_sym
      @exit_code = data["exit_code"]
      @signal = data["signal"]
      @source = data["source"]
      @observed_at_ms = data["observed_at_ms"]
    end

    def stopped? = @status == :stopped
    def crashed? = @status == :crashed

    # @return [Time] when the stopped state was observed
    def observed_at
      Time.at(@observed_at_ms / 1000.0)
    end

    def inspect
      "#<Microsandbox::SandboxStopResult name=#{@name.inspect} status=#{@status}" \
        "#{" exit_code=#{@exit_code}" if @exit_code}#{" signal=#{@signal}" if @signal}>"
    end
  end

  # A running sandbox (microVM) — the primary entry point of the SDK.
  #
  # @example Block form (auto-stops on exit)
  #   Microsandbox::Sandbox.create("hello", image: "python") do |sb|
  #     out = sb.exec("python", ["-c", "print('hi')"])
  #     puts out.stdout
  #   end
  #
  # @example Manual lifecycle
  #   sb = Microsandbox::Sandbox.create("hello", image: "python")
  #   begin
  #     sb.shell("echo hi")
  #   ensure
  #     sb.stop
  #   end
  class Sandbox
    # Recognized disk-image rootfs extensions, mirroring the upstream
    # `DiskImageFormat::from_extension`/`FromStr` set. Used by {disk_image_rootfs?}
    # to gate the `fstype:`-vs-OCI check; keep in sync on a runtime-tag bump.
    DISK_IMAGE_EXTENSIONS = %w[raw qcow2 vmdk].freeze

    class << self
      # Create and boot a sandbox.
      #
      # When a block is given the sandbox is yielded and stopped automatically
      # when the block returns (the block's value is returned); otherwise the
      # live {Sandbox} is returned and you are responsible for calling {#stop}.
      #
      # @param name [String] sandbox name (max 128 UTF-8 bytes)
      # @param image [String, nil] OCI image reference (e.g. "python")
      # @param cpus [Integer, nil] number of vCPUs
      # @param memory [Integer, nil] memory in MiB
      # @param env [Hash, nil] environment variables
      # @param workdir [String, nil] working directory inside the guest
      # @param shell [String, nil] default shell (for {#shell})
      # @param user [String, nil] default user
      # @param hostname [String, nil] guest hostname
      # @param labels [Hash, nil] metadata labels
      # @param scripts [Hash, nil] named scripts to install
      # @param entrypoint [Array<String>, nil] image entrypoint override
      # @param ports [Hash, nil] host_port => guest_port TCP publications
      # @param ports_udp [Hash, nil] host_port => guest_port UDP publications
      # @param volumes [Hash, nil] guest_path => mount spec. Each value is a host
      #   path String (a bind mount), or a Hash: `{ bind: "/host" }`,
      #   `{ named: "vol" }`, `{ tmpfs: true, size_mib: 64 }`, or
      #   `{ disk: "/img.raw", format: "raw", fstype: "ext4" }`. Any mount may add
      #   flags `ro:`/`readonly:`, `noexec:`, `nosuid:`, `nodev:`, and (bind/named
      #   only) `stat_virtualization:` (:strict/:relaxed/:off) and
      #   `host_permissions:` (:private/:mirror).
      # @param network [String, Symbol, NetworkPolicy, Hash, nil] network policy.
      #   A preset name ("public_only" (default), "none", "allow_all",
      #   "non_local"), a {NetworkPolicy} (e.g. {NetworkPolicy.custom}), or a Hash
      #   describing a custom policy (`default_egress:`, `default_ingress:`,
      #   `rules:`, `deny_domains:`, `deny_domain_suffixes:`). See {NetworkPolicy}
      #   and {Rule}.
      # @param dns [Hash, nil] custom DNS: `{ nameservers: [...],
      #   rebind_protection: true, query_timeout_ms: 2000 }`
      # @param tls [Hash, nil] TLS-interception tuning: `{ bypass: [...patterns],
      #   verify_upstream: true, intercepted_ports: [443, 8443], block_quic: true,
      #   upstream_ca_cert:, intercept_ca_cert:, intercept_ca_key: }` (paths). Use
      #   this to inject `secrets:` on non-443 ports or to trust a private CA.
      # @param ipv4_pool [String, nil] guest IPv4 address pool CIDR (e.g. "10.0.0.0/24")
      # @param ipv6_pool [String, nil] guest IPv6 address pool CIDR
      # @param max_connections [Integer, nil] cap on concurrent proxied connections
      # @param trust_host_cas [Boolean, nil] trust the host's CA bundle for upstream TLS
      # @param from_snapshot [String, nil] boot from a snapshot name or digest
      #   instead of an image (mutually exclusive with `image:`)
      # @param fstype [String, nil] inner filesystem type (e.g. "ext4") when
      #   `image:` is a disk-image rootfs path whose filesystem can't be
      #   auto-probed; ignored for OCI images
      # @param init [String, Hash, nil] hand guest PID 1 to an init system: a
      #   command path (e.g. "/lib/systemd/systemd" or "auto"), or a Hash
      #   `{ cmd:, args:, env: }` when the init binary takes argv/extra env
      # @param ephemeral [Boolean] auto-remove the sandbox's stored state (DB
      #   row, disk, logs, captured output) once it reaches a terminal state
      #   (default: state is persisted until {.remove})
      # @param patches [Array<Hash>, nil] rootfs patches applied before boot, each
      #   built with the {Patch} factory (e.g. `Patch.text(...)`, `Patch.mkdir(...)`).
      #   Not compatible with disk-image roots.
      # @param log_level ["error","warn","info","debug","trace", nil] guest log verbosity
      # @param quiet_logs [Boolean] suppress sandbox process logs
      # @param security ["default", "restricted", nil] exec security profile
      # @param oci_upper_size [Integer, nil] writable upper-layer size cap, in MiB
      # @param max_duration [Integer, nil] hard wall-clock lifetime, in seconds
      # @param idle_timeout [Integer, nil] stop after this many idle seconds
      # @param rlimits [Hash, nil] resource limits: { resource => limit } or
      #   { resource => [soft, hard] } (e.g. { nofile: 65_535 })
      # @param pull_policy ["always","if-missing","never", nil] image pull behavior
      # @param registry_auth [Hash, nil] credentials for a private/authenticated
      #   registry: { username:, password: } (the password may be a token).
      #   Without this the core's default resolution chain still applies (OS
      #   keyring, global config, `~/.docker/config.json`).
      # @param registry_insecure [Boolean] reach the registry over plain HTTP
      #   instead of HTTPS (for local/self-hosted registries)
      # @param registry_ca_certs [String, Array<String>, nil] extra PEM-encoded CA
      #   root certificate(s) to trust (for a registry with a private CA)
      # @param secrets [Array<Hash>, nil] placeholder-protected secrets injected by
      #   the TLS proxy (auto-enables TLS interception). Each Hash needs `env:` and
      #   `value:` plus an allow list — `host:` (single), `hosts:` (Array), and/or
      #   `host_patterns:` (wildcards like "*.stripe.com"). Optional per-secret:
      #   `placeholder:`, `require_tls:`, injection toggles `inject_headers:` /
      #   `inject_basic_auth:` / `inject_query:` / `inject_body:`, and `on_violation:`.
      # @param on_secret_violation [String, Symbol, Hash, nil] sandbox-wide
      #   secret-leak policy: "block", "block_and_log", "block_and_terminate",
      #   "passthrough" (passthrough-all-hosts), or a Hash
      #   `{ passthrough_hosts:, passthrough_host_patterns:, passthrough_all_hosts: }`
      # @param detached [Boolean] keep running after this process exits
      # @param replace [Boolean] replace an existing sandbox with the same name
      # @param replace_with_timeout [Numeric, nil] replace, waiting up to N seconds
      # @yieldparam sandbox [Sandbox]
      # @return [Sandbox, Object] the sandbox, or the block's return value
      def create(name, **kwargs, &block)
        opts = build_create_opts(**kwargs)
        sandbox = new(Native::Sandbox.create(name.to_s, opts))
        return sandbox unless block_given?

        begin
          yield sandbox
        ensure
          begin
            sandbox.stop
          rescue Microsandbox::Error
            # best-effort cleanup; ignore stop failures during teardown
          end
        end
      end

      # Create a sandbox while streaming image-pull progress. Accepts the same
      # options as {create}; returns a {PullSession} — iterate it (an
      # {Enumerable} of progress-event Hashes, each with a "kind"), then call
      # {PullSession#sandbox} for the booted {Sandbox}. Mirrors the Python
      # `create_with_progress` / Node `createWithPullProgress`.
      # @return [PullSession]
      def create_with_progress(name, **kwargs)
        # Unlike {create}, this has no block form: the booted sandbox is reached
        # via {PullSession#sandbox} (after iterating progress) and stopped by the
        # caller. A block would be silently dropped — and the sandbox leaked — so
        # reject it loudly rather than let a `create`-style block call misfire.
        if block_given?
          raise ArgumentError,
            "create_with_progress takes no block; iterate the returned PullSession " \
            "for progress, then call #sandbox and stop it when done"
        end
        opts = build_create_opts(**kwargs)
        PullSession.new(Native::Sandbox.create_with_progress(name.to_s, opts))
      end

      # @api private
      # Shared keyword-option builder for {create}/{create_with_progress}.
      def build_create_opts(image: nil, cpus: nil, memory: nil, env: nil, workdir: nil,
        shell: nil, user: nil, hostname: nil, labels: nil, scripts: nil,
        entrypoint: nil, ports: nil, ports_udp: nil, volumes: nil, network: nil,
        dns: nil, tls: nil, ipv4_pool: nil, ipv6_pool: nil,
        max_connections: nil, trust_host_cas: nil,
        patches: nil,
        from_snapshot: nil, fstype: nil, init: nil, ephemeral: false,
        log_level: nil, quiet_logs: false, security: nil,
        oci_upper_size: nil, max_duration: nil, idle_timeout: nil, rlimits: nil,
        pull_policy: nil, registry_auth: nil, registry_insecure: false,
        registry_ca_certs: nil, secrets: nil, on_secret_violation: nil,
        detached: false, replace: false, replace_with_timeout: nil)
        # A sandbox boots from exactly one rootfs source. The core would reject a
        # contradictory pair, but only after a runtime round-trip; fail fast and
        # clearly here (the Python SDK validates this the same way).
        if image && from_snapshot
          raise ArgumentError, "provide either image: or from_snapshot:, not both"
        end
        Microsandbox.ensure_runtime!
        # `fstype:` names the inner filesystem of a disk-image rootfs, so it only
        # applies when `image:` is a disk-image path (a local path ending in
        # .raw/.qcow2/.vmdk). Routing an OCI ref (e.g. "python") through the
        # disk-image builder would make the core treat it as a host disk path and
        # fail at boot, so reject the combination up front instead of forwarding a
        # value the native layer can't honour.
        if fstype && !disk_image_rootfs?(image)
          raise ArgumentError,
            "fstype: only applies to a disk-image rootfs; image: must be a local " \
            "path ending in .raw, .qcow2, or .vmdk (got #{image.inspect}). " \
            "OCI references auto-detect their filesystem — drop fstype:."
        end
        opts = {}
        opts["image"] = image.to_s if image
        opts["from_snapshot"] = from_snapshot.to_s if from_snapshot
        opts["fstype"] = fstype.to_s if fstype
        opts["cpus"] = Integer(cpus) if cpus
        opts["memory"] = Integer(memory) if memory
        opts["workdir"] = workdir.to_s if workdir
        opts["shell"] = shell.to_s if shell
        opts["user"] = user.to_s if user
        opts["hostname"] = hostname.to_s if hostname
        opts["env"] = stringify(env) if env
        opts["labels"] = stringify(labels) if labels
        opts["scripts"] = stringify(scripts) if scripts
        opts["entrypoint"] = Array(entrypoint).map(&:to_s) if entrypoint
        opts["ports"] = intify_ports(ports) if ports
        opts["ports_udp"] = intify_ports(ports_udp) if ports_udp
        opts["volumes"] = normalize_volumes(volumes) if volumes
        opts["patches"] = normalize_patches(patches) if patches
        apply_network_opts(opts, network) unless network.nil?
        opts["dns"] = normalize_dns(dns) if dns
        opts["tls"] = normalize_tls(tls) if tls
        opts["ipv4_pool"] = ipv4_pool.to_s if ipv4_pool
        opts["ipv6_pool"] = ipv6_pool.to_s if ipv6_pool
        opts["max_connections"] = Integer(max_connections) if max_connections
        set_bool(opts, "trust_host_cas", trust_host_cas)
        opts["log_level"] = log_level.to_s if log_level
        opts["quiet_logs"] = true if quiet_logs
        opts["security"] = security.to_s if security
        opts["oci_upper_size"] = Integer(oci_upper_size) if oci_upper_size
        opts["max_duration"] = Integer(max_duration) if max_duration
        opts["idle_timeout"] = Integer(idle_timeout) if idle_timeout
        opts["rlimits"] = normalize_rlimits(rlimits) if rlimits
        opts["pull_policy"] = pull_policy.to_s if pull_policy
        apply_registry_opts(opts, registry_auth, registry_insecure, registry_ca_certs)
        opts["secrets"] = normalize_secrets(secrets) if secrets
        opts["on_secret_violation"] = normalize_violation(on_secret_violation) if on_secret_violation
        opts["init"] = normalize_init(init) unless init.nil?
        opts["ephemeral"] = true if ephemeral
        opts["detached"] = true if detached
        if replace_with_timeout
          opts["replace_with_timeout"] = coerce_duration(replace_with_timeout, "replace_with_timeout")
        elsif replace
          opts["replace"] = true
        end

        opts
      end

      # Restart a previously-defined sandbox by name.
      # @return [Sandbox]
      def start(name, detached: false)
        Microsandbox.ensure_runtime!
        new(Native::Sandbox.start(name.to_s, {"detached" => detached}))
      end

      # Fetch a controllable handle for a sandbox by name (running or not).
      # @return [SandboxHandle]
      def get(name)
        SandboxHandle.new(Native::Sandbox.get(name.to_s))
      end

      # List all sandboxes as controllable handles.
      # @return [Array<SandboxHandle>]
      def list
        Native::Sandbox.list.map { |h| SandboxHandle.new(h) }
      end

      # List sandboxes carrying all of the given labels (AND-matched).
      # @param labels [Hash] required key => value labels
      # @return [Array<SandboxHandle>]
      def list_with(labels: {})
        opts = {"labels" => stringify(labels)}
        Native::Sandbox.list_with(opts).map { |h| SandboxHandle.new(h) }
      end

      # Remove a (stopped) sandbox by name.
      # @return [nil]
      def remove(name)
        Native::Sandbox.remove(name.to_s)
        nil
      end

      private

      # Coerce a seconds value to a finite, non-negative Float. Rejects negatives,
      # NaN, and infinities *here* (a clean ArgumentError) rather than letting them
      # reach the native layer, where `Duration::from_secs_f64` panics across the
      # FFI boundary on exactly those inputs. Shared by every duration option.
      def coerce_duration(value, label)
        seconds = Float(value)
        unless seconds.finite? && seconds >= 0
          raise ArgumentError,
            "#{label} must be a finite, non-negative number of seconds (got #{value.inspect})"
        end
        seconds
      end

      def stringify(hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
      end

      def intify_ports(ports)
        ports.each_with_object({}) { |(k, v), acc| acc[Integer(k)] = Integer(v) }
      end

      # Normalize the `init:` option into the native { "cmd" =>, "args" =>,
      # "env" => } shape. Accepts a bare command (String/Symbol — an init binary
      # path or the literal "auto") or a Hash { cmd:, args:, env: }, mirroring the
      # Python InitConfig / Node init options.
      def normalize_init(init)
        case init
        when String, Symbol
          {"cmd" => init.to_s}
        when Hash
          cmd = init[:cmd] || init["cmd"]
          raise ArgumentError, "init: requires a :cmd" unless cmd
          spec = {"cmd" => cmd.to_s}
          args = init[:args] || init["args"]
          spec["args"] = Array(args).map(&:to_s) if args
          env = init[:env] || init["env"]
          spec["env"] = stringify(env) if env
          spec
        else
          raise ArgumentError, "init: must be a String command or a Hash {cmd:, args:, env:}"
        end
      end

      # Flatten the registry options into the native layer's `registry_*` keys.
      # `auth` is a Hash { username:, password: } (string or symbol keys); both
      # are required when given. `ca_certs` accepts one PEM string or an Array.
      def apply_registry_opts(opts, auth, insecure, ca_certs)
        if auth
          username = auth[:username] || auth["username"]
          password = auth[:password] || auth["password"]
          unless username && password
            # Report only the keys given, never the values — auth carries secrets.
            raise ArgumentError,
              "registry_auth needs :username and :password (got keys: #{auth.keys.inspect})"
          end
          opts["registry_username"] = username.to_s
          opts["registry_password"] = password.to_s
        end
        opts["registry_insecure"] = true if insecure
        opts["registry_ca_certs"] = Array(ca_certs).map(&:to_s) if ca_certs
      end

      # Normalize secrets into per-secret string-keyed Hashes for the native
      # layer. Each entry is a Hash (string or symbol keys); required :env and
      # :value, plus at least one allowed host via :host (single), :hosts (Array),
      # or :host_patterns (Array of wildcards like "*.stripe.com"). Optional:
      # :placeholder, :require_tls, the injection toggles :inject_headers /
      # :inject_basic_auth / :inject_query / :inject_body, and :on_violation (see
      # {#normalize_violation}).
      def normalize_secrets(secrets)
        Array(secrets).map { |spec| normalize_secret(spec) }
      end

      def normalize_secret(spec)
        env = spec[:env] || spec["env"]
        value = spec[:value] || spec["value"]
        unless env && value
          raise ArgumentError, "secret spec needs :env and :value (got #{spec.inspect})"
        end
        out = {"env" => env.to_s, "value" => value.to_s}
        hosts = Array(spec[:hosts] || spec["hosts"]).map(&:to_s)
        single = spec[:host] || spec["host"]
        hosts << single.to_s if single
        patterns = Array(spec[:host_patterns] || spec["host_patterns"]).map(&:to_s)
        if hosts.empty? && patterns.empty?
          raise ArgumentError,
            "secret spec needs :host, :hosts, or :host_patterns (got #{spec.inspect})"
        end
        out["hosts"] = hosts unless hosts.empty?
        out["host_patterns"] = patterns unless patterns.empty?
        pl = spec[:placeholder] || spec["placeholder"]
        out["placeholder"] = pl.to_s if pl
        # Booleans must honor an explicit `false` (to disable a default-on toggle),
        # so probe key presence rather than truthiness.
        %i[require_tls inject_headers inject_basic_auth inject_query inject_body].each do |k|
          set_bool(out, k.to_s, fetch_opt(spec, k))
        end
        ov = spec[:on_violation] || spec["on_violation"]
        out["on_violation"] = normalize_violation(ov) if ov
        out
      end

      # Read a symbol-or-string key from a Hash, distinguishing an explicit
      # `false`/`nil` value from an absent key.
      def fetch_opt(spec, sym)
        return spec[sym] if spec.key?(sym)
        spec[sym.to_s]
      end

      # Write a boolean option onto `out`, honoring an explicit `false` (to
      # disable a default-on toggle) while leaving an absent (`nil`) value unset.
      # Centralizes the "probe presence, not truthiness" rule for all the boolean
      # toggles (require_tls/inject_*/verify_upstream/block_quic/rebind_protection/
      # trust_host_cas) so a future toggle can't silently drop a `false`.
      def set_bool(out, key, value)
        out[key] = (value ? true : false) unless value.nil?
      end

      # Normalize an `on_violation`/`on_secret_violation` spec for the native
      # layer: a String/Symbol block variant ("block"/"block_and_log"/
      # "block_and_terminate"), or a Hash describing a passthrough action
      # ({ passthrough_hosts:, passthrough_host_patterns:, passthrough_all_hosts: }).
      def normalize_violation(spec)
        case spec
        when String, Symbol
          # The bare "passthrough" string maps to passthrough-all-hosts, matching
          # the Python/Node SDKs (so a string-form policy copied from another SDK
          # ports over unchanged); block variants stay as their action string.
          if spec.to_s.strip.downcase.tr("-", "_") == "passthrough"
            {"passthrough_all_hosts" => true}
          else
            normalize_violation_action(spec)
          end
        when Hash
          hosts = Array(spec[:passthrough_hosts] || spec["passthrough_hosts"]).map(&:to_s)
          patterns = Array(spec[:passthrough_host_patterns] || spec["passthrough_host_patterns"]).map(&:to_s)
          all = !!(spec[:passthrough_all_hosts] || spec["passthrough_all_hosts"])
          # An empty passthrough (no hosts, no patterns, not all) passes nothing
          # through — a no-op the native builder silently degrades to its default
          # action. Reject it with actionable guidance rather than accept a spec
          # that does nothing the caller intended.
          if hosts.empty? && patterns.empty? && !all
            raise ArgumentError,
              "passthrough on_violation needs at least one of :passthrough_hosts, " \
              ":passthrough_host_patterns, or :passthrough_all_hosts (use \"block\" " \
              "if blocking is the intent)"
          end
          out = {}
          out["passthrough_hosts"] = hosts unless hosts.empty?
          out["passthrough_host_patterns"] = patterns unless patterns.empty?
          out["passthrough_all_hosts"] = true if all
          out
        else
          raise ArgumentError, "on_violation must be a String or a Hash (got #{spec.inspect})"
        end
      end

      # Map a block-variant action onto the canonical underscore spelling the
      # native layer expects. Also accepts the upstream kebab-case wire spellings
      # ("block-and-log"/"block-and-terminate") used by the CLI, Go SDK, and
      # sandbox config files, so a policy copied from another SDK ports over
      # unchanged instead of being rejected.
      def normalize_violation_action(spec)
        action = spec.to_s.strip.downcase.tr("-", "_")
        unless %w[block block_and_log block_and_terminate].include?(action)
          raise ArgumentError,
            "unknown on_violation #{spec.inspect} (expected block, " \
            "block_and_log/block-and-log, block_and_terminate/block-and-terminate, " \
            "passthrough, or a Hash with :passthrough_hosts/:passthrough_host_patterns/:passthrough_all_hosts)"
        end
        action
      end

      # Normalize the `dns:` config Hash for the native layer.
      def normalize_dns(dns)
        raise ArgumentError, "dns: must be a Hash" unless dns.is_a?(Hash)
        out = {}
        ns = dns[:nameservers] || dns["nameservers"]
        out["nameservers"] = Array(ns).map(&:to_s) if ns
        set_bool(out, "rebind_protection", fetch_opt(dns, :rebind_protection))
        qt = dns[:query_timeout_ms] || dns["query_timeout_ms"]
        out["query_timeout_ms"] = Integer(qt) if qt
        out
      end

      # Normalize the `tls:` interception-tuning Hash for the native layer.
      def normalize_tls(tls)
        raise ArgumentError, "tls: must be a Hash" unless tls.is_a?(Hash)
        out = {}
        bypass = tls[:bypass] || tls["bypass"]
        out["bypass"] = Array(bypass).map(&:to_s) if bypass
        set_bool(out, "verify_upstream", fetch_opt(tls, :verify_upstream))
        ports = tls[:intercepted_ports] || tls["intercepted_ports"]
        out["intercepted_ports"] = Array(ports).map { |p| Integer(p) } if ports
        set_bool(out, "block_quic", fetch_opt(tls, :block_quic))
        %i[upstream_ca_cert intercept_ca_cert intercept_ca_key].each do |k|
          v = tls[k] || tls[k.to_s]
          out[k.to_s] = v.to_s if v
        end
        out
      end

      # Normalize an rlimits Hash into [resource, soft, hard] triples for the
      # native layer. Each value is either a single limit (soft == hard) or a
      # [soft, hard] pair. Shared by {Sandbox.create} and {Sandbox#exec}.
      def normalize_rlimits(rlimits)
        rlimits.map do |resource, limit|
          soft, hard = limit.is_a?(Array) ? [limit[0], limit[1]] : [limit, limit]
          [resource.to_s, Integer(soft), Integer(hard)]
        end
      end

      # True when `image` names a disk-image rootfs the way the core auto-detects
      # one: a local-path-looking string (`/`, `./`, `../` prefix) whose extension
      # is a recognized disk-image format. This re-implements two upstream
      # heuristics the native layer can't reach from here (the `microsandbox`
      # crate re-exports neither): `looks_like_local_path_text`
      # (microsandbox/crates/utils/lib/lib.rs) and `DiskImageFormat::from_extension`
      # / `FromStr` (microsandbox/packages/microsandbox-types/rust/lib/domain.rs,
      # qcow2/raw/vmdk). Keep both in sync when bumping the pinned runtime tag —
      # the "disk_image_rootfs? contract" examples in sandbox_spec.rb pin it.
      def disk_image_rootfs?(image)
        s = image.to_s
        return false unless s.start_with?("/", "./", "../")
        DISK_IMAGE_EXTENSIONS.include?(File.extname(s).delete_prefix(".").downcase)
      end

      # Normalize volumes (Hash of guest_path => spec) into per-mount string-keyed
      # Hashes for the native layer. A spec is a host path String (a read-write
      # bind mount) or a Hash describing the mount:
      #   { bind: "/host", ro: true, noexec: true }            # host bind mount
      #   { named: "vol" }                                       # named volume
      #   { tmpfs: true, size_mib: 64 }                          # memory-backed
      #   { disk: "/img.raw", format: "raw", fstype: "ext4" }   # disk-image mount
      # Any mount may also carry stat_virtualization: (:strict/:relaxed/:off) and
      # host_permissions: (:private/:mirror).
      def normalize_volumes(volumes)
        volumes.map do |guest, spec|
          mount = {"guest" => guest.to_s}
          case spec
          when String
            mount["kind"] = "bind"
            mount["source"] = spec
          when Hash
            apply_mount_kind(mount, spec, guest)
            apply_mount_flags(mount, spec)
          else
            raise ArgumentError, "invalid volume spec for #{guest.inspect}: #{spec.inspect}"
          end
          mount
        end
      end

      # Resolve a volume spec Hash's mount kind + source/size/format/fstype.
      def apply_mount_kind(mount, spec, guest)
        if (bind = spec[:bind] || spec["bind"])
          mount["kind"] = "bind"
          mount["source"] = bind.to_s
        elsif (named = spec[:named] || spec["named"])
          mount["kind"] = "named"
          mount["source"] = named.to_s
        elsif spec[:tmpfs] || spec["tmpfs"]
          mount["kind"] = "tmpfs"
        elsif (disk = spec[:disk] || spec["disk"])
          mount["kind"] = "disk"
          mount["source"] = disk.to_s
          fmt = spec[:format] || spec["format"]
          mount["format"] = fmt.to_s if fmt
        else
          raise ArgumentError,
            "volume spec for #{guest.inspect} needs :bind, :named, :tmpfs, or :disk"
        end
        size = spec[:size_mib] || spec["size_mib"]
        mount["size_mib"] = Integer(size) if size
        fstype = spec[:fstype] || spec["fstype"]
        mount["fstype"] = fstype.to_s if fstype
      end

      # Apply a volume spec Hash's mount flags. `ro:`/`readonly:` makes the mount
      # read-only; `noexec:`/`nosuid:`/`nodev:` set the matching flags;
      # `stat_virtualization:`/`host_permissions:` set the passthrough policies
      # (only valid on bind/named — the core rejects them on tmpfs/disk).
      def apply_mount_flags(mount, spec)
        mount["readonly"] = true if spec[:ro] || spec["ro"] || spec[:readonly] || spec["readonly"]
        mount["noexec"] = true if spec[:noexec] || spec["noexec"]
        mount["nosuid"] = true if spec[:nosuid] || spec["nosuid"]
        mount["nodev"] = true if spec[:nodev] || spec["nodev"]
        apply_legacy_mount_options(mount, spec)
        sv = spec[:stat_virtualization] || spec["stat_virtualization"]
        mount["stat_virtualization"] = sv.to_s if sv
        hp = spec[:host_permissions] || spec["host_permissions"]
        mount["host_permissions"] = hp.to_s if hp
      end

      # Translate the pre-0.7.0 `options:` array form (e.g. options: %w[ro noexec])
      # onto the discrete boolean flags the native layer now consumes. Kept for
      # backward compatibility with configs written against 0.5.11–0.6.0. Unknown
      # tokens raise rather than being silently dropped: a mount requested
      # read-only/noexec that quietly mounted read-write/executable would be a
      # security regression, not a cosmetic one.
      def apply_legacy_mount_options(mount, spec)
        Array(spec[:options] || spec["options"]).each do |opt|
          case opt.to_s
          when "ro", "readonly" then mount["readonly"] = true
          # "rw" is read-write, the default — accepted as a no-op (the pre-0.7.0
          # native validator and the upstream wire form both treat it that way).
          # Dropping it would break a previously-valid `options:` array, which the
          # CHANGELOG promises is still honored.
          when "rw" then nil
          when "noexec" then mount["noexec"] = true
          when "nosuid" then mount["nosuid"] = true
          when "nodev" then mount["nodev"] = true
          else
            raise ArgumentError,
              "unknown mount option #{opt.inspect} in options: — use " \
              "ro/readonly, rw, noexec, nosuid, or nodev (or the matching boolean keys)"
          end
        end
      end

      # Normalize a list of patches (each a Hash from the {Patch} factory, or a
      # plain Hash) into string-keyed Hashes for the native layer. Values are
      # passed through unchanged (mode stays Integer, content stays String).
      def normalize_patches(patches)
        Array(patches).map do |p|
          unless p.is_a?(Hash)
            raise ArgumentError, "patch must be a Hash (use Microsandbox::Patch.*): #{p.inspect}"
          end
          p.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
        end
      end

      # Route the `network:` argument to either the preset path
      # (`opts["network"]`, the original string-preset behavior) or the custom
      # policy path (`opts["network_policy"]`). Accepts a preset String/Symbol, a
      # {NetworkPolicy}, or a plain Hash.
      def apply_network_opts(opts, network)
        norm = NetworkPolicy.coerce(network)
        return if norm.empty? # e.g. network: {} — leave the default policy in place

        if norm.keys == ["preset"]
          opts["network"] = norm["preset"]
        else
          opts["network_policy"] = norm
        end
      end
    end

    def initialize(native)
      @native = native
    end

    # @return [String] the sandbox name
    def name
      @native.name
    end

    # Run a command (no shell interpretation) and collect its output.
    #
    # @param command [String] the executable
    # @param args [Array<String>] arguments
    # @param cwd [String, nil] working directory
    # @param user [String, nil] user to run as
    # @param env [Hash, nil] extra environment variables
    # @param timeout [Numeric, nil] kill after N seconds
    # @param tty [Boolean] allocate a pseudo-terminal
    # @param stdin [String, Symbol, nil] bytes to feed to stdin, or +:pipe+ to
    #   open a streaming stdin pipe (write/close it via {ExecHandle#stdin}; only
    #   useful with the streaming variants)
    # @return [ExecOutput]
    def exec(command, args = [], cwd: nil, user: nil, env: nil, timeout: nil, tty: false, stdin: nil, rlimits: nil)
      ExecOutput.new(@native.exec(command.to_s, Array(args).map(&:to_s),
        exec_opts(cwd:, user:, env:, timeout:, tty:, stdin:, rlimits:)))
    end

    # Run a shell script (pipes, redirects, etc. allowed) and collect output.
    # @return [ExecOutput]
    def shell(script, cwd: nil, user: nil, env: nil, timeout: nil, tty: false, stdin: nil, rlimits: nil)
      ExecOutput.new(@native.shell(script.to_s,
        exec_opts(cwd:, user:, env:, timeout:, tty:, stdin:, rlimits:)))
    end

    # Run a command and stream its output as it arrives.
    #
    # Pass +stdin: :pipe+ to feed the process interactively: {ExecHandle#stdin}
    # then returns a writable sink; close it to send EOF (a process like +cat+
    # that reads until EOF will otherwise block forever).
    # @return [ExecHandle]
    # @see ExecHandle
    def exec_stream(command, args = [], cwd: nil, user: nil, env: nil, timeout: nil, tty: false, stdin: nil, rlimits: nil)
      ExecHandle.new(@native.exec_stream(command.to_s, Array(args).map(&:to_s),
        exec_opts(cwd:, user:, env:, timeout:, tty:, stdin:, rlimits:, pipe_ok: true)))
    end

    # Run a shell script and stream its output as it arrives.
    # @return [ExecHandle]
    def shell_stream(script, cwd: nil, user: nil, env: nil, timeout: nil, tty: false, stdin: nil, rlimits: nil)
      ExecHandle.new(@native.shell_stream(script.to_s,
        exec_opts(cwd:, user:, env:, timeout:, tty:, stdin:, rlimits:, pipe_ok: true)))
    end

    # Attach an interactive terminal to a command in the sandbox.
    #
    # Puts the **host** terminal into raw mode and forwards keystrokes (and
    # SIGWINCH resizes) to the guest until the command exits or the detach
    # sequence is typed. Requires a real TTY on stdin/stdout, so it is for CLI
    # use, not library/automation code (use {#exec}/{#exec_stream} there). Blocks
    # until the session ends. Mirrors the official SDKs' `attach`.
    #
    # @param command [String] the program to run
    # @param args [Array<String>] its arguments
    # @param cwd [String, nil] working directory
    # @param user [String, nil] user to run as
    # @param env [Hash, nil] extra environment variables
    # @param detach_keys [String, nil] detach sequence (e.g. "ctrl-p,ctrl-q";
    #   default "ctrl-]")
    # @param rlimits [Hash, nil] resource limits (see {#exec})
    # @return [Integer] the command's exit code (or the code at detach)
    def attach(command, args = [], cwd: nil, user: nil, env: nil, detach_keys: nil, rlimits: nil)
      opts = {}
      opts["cwd"] = cwd.to_s if cwd
      opts["user"] = user.to_s if user
      opts["env"] = env.each_with_object({}) { |(k, v), a| a[k.to_s] = v.to_s } if env
      opts["detach_keys"] = detach_keys.to_s if detach_keys
      if rlimits
        opts["rlimits"] = rlimits.map do |resource, limit|
          soft, hard = limit.is_a?(Array) ? [limit[0], limit[1]] : [limit, limit]
          [resource.to_s, Integer(soft), Integer(hard)]
        end
      end
      @native.attach(command.to_s, Array(args).map(&:to_s), opts)
    end

    # Attach an interactive terminal running the sandbox's default shell.
    # See {#attach} for the host-TTY requirements.
    # @return [Integer] the shell's exit code (or the code at detach)
    def attach_shell
      @native.attach_shell
    end

    # Guest filesystem operations.
    # @return [FS]
    def fs
      @fs ||= FS.new(@native)
    end

    # SSH access to the sandbox — open a native in-process SSH client or prepare
    # a reusable server endpoint.
    # @return [SshOps]
    # @example
    #   sb.ssh.open_client { |c| puts c.exec("hostname").stdout }
    def ssh
      SshOps.new(@native)
    end

    # Latest resource-usage snapshot.
    # @return [Metrics]
    def metrics
      Metrics.new(@native.metrics)
    end

    # Read captured logs.
    #
    # @param tail [Integer, nil] only the last N entries
    # @param since_ms [Numeric, nil] only entries at/after this Unix ms
    # @param until_ms [Numeric, nil] only entries before this Unix ms
    # @param sources [Array<String,Symbol>, nil] filter by source
    #   ("stdout"/"stderr"/"output"/"system"/"all")
    # @return [Array<LogEntry>]
    def logs(tail: nil, since_ms: nil, until_ms: nil, sources: nil)
      opts = {}
      opts["tail"] = Integer(tail) if tail
      opts["since_ms"] = Float(since_ms) if since_ms
      opts["until_ms"] = Float(until_ms) if until_ms
      opts["sources"] = Array(sources).map(&:to_s) if sources
      @native.logs(opts).map { |entry| LogEntry.new(entry) }
    end

    # Stream resource-usage snapshots, one per interval tick, until the sandbox
    # stops. Requires metrics to be enabled for the sandbox.
    # @param interval [Numeric] seconds between snapshots
    # @return [MetricsStream] an {Enumerable} of {Metrics}
    def metrics_stream(interval: 1.0)
      MetricsStream.new(@native.metrics_stream(coerce_duration(interval, "interval")))
    end

    # Stream captured logs as they appear.
    #
    # @param sources [Array<String,Symbol>, nil] filter by source
    #   ("stdout"/"stderr"/"output"/"system"/"all")
    # @param since_ms [Numeric, nil] start at the first entry at/after this Unix ms
    # @param from_cursor [String, nil] resume exactly after a prior {LogEntry#cursor}
    #   (mutually exclusive with since_ms; takes precedence if both given)
    # @param until_ms [Numeric, nil] stop before any entry at/after this Unix ms
    # @param follow [Boolean] keep the stream open for new entries past current EOF
    # @return [LogStream] an {Enumerable} of {LogEntry}
    def log_stream(sources: nil, since_ms: nil, from_cursor: nil, until_ms: nil, follow: false)
      opts = {}
      opts["sources"] = Array(sources).map(&:to_s) if sources
      opts["since_ms"] = Float(since_ms) if since_ms
      opts["from_cursor"] = from_cursor.to_s if from_cursor
      opts["until_ms"] = Float(until_ms) if until_ms
      opts["follow"] = true if follow
      LogStream.new(@native.log_stream(opts))
    end

    # Gracefully stop the sandbox (SIGTERM→SIGKILL escalation, 10s default) and
    # wait for it to terminate. For a custom timeout or fire-and-return
    # `request_*` control, fetch a {SandboxHandle} via {Sandbox.get}.
    # @return [nil]
    def stop
      @native.stop
      nil
    end

    # Gracefully stop, then wait for the process to exit.
    # @return [ExitStatus]
    def stop_and_wait
      ExitStatus.new(@native.stop_and_wait)
    end

    # Force-kill the sandbox (SIGKILL).
    # @return [nil]
    def kill
      @native.kill
      nil
    end

    # Trigger a graceful drain (SIGUSR1).
    # @return [nil]
    def drain
      @native.drain
      nil
    end

    # Wait for the sandbox process to exit.
    # @return [ExitStatus]
    def wait
      ExitStatus.new(@native.wait)
    end

    # The live status, fetched from the backend (a round-trip per call).
    # @return [Symbol] :created, :starting, :running, :draining, :paused,
    #   :stopped, or :crashed
    def status
      @native.status.to_sym
    end

    # @return [Boolean] whether this handle owns the sandbox process lifecycle
    #   (i.e. stopping it or dropping the handle terminates the sandbox)
    def owns_lifecycle?
      @native.owns_lifecycle
    end

    # Detach this handle: disarm the stop-on-drop safety net so the sandbox
    # keeps running after this handle is gone (and after this process exits).
    # @return [nil]
    def detach
      @native.detach
      nil
    end

    def inspect
      "#<Microsandbox::Sandbox name=#{name.inspect}>"
    end

    private

    # Instance-side shim for the shared, class-private duration validator (used
    # by #exec/#shell timeouts, #stop/#kill, and #metrics_stream).
    def coerce_duration(value, label)
      self.class.send(:coerce_duration, value, label)
    end

    def exec_opts(cwd:, user:, env:, timeout:, tty:, stdin:, rlimits:, pipe_ok: false)
      opts = {}
      opts["cwd"] = cwd.to_s if cwd
      opts["user"] = user.to_s if user
      opts["env"] = env.each_with_object({}) { |(k, v), a| a[k.to_s] = v.to_s } if env
      opts["timeout"] = coerce_duration(timeout, "timeout") if timeout
      opts["tty"] = true if tty
      # stdin is a closed set of modes, mirroring the official SDKs:
      #   nil / :null  — no stdin (the guest sees /dev/null)
      #   :pipe        — open a streaming stdin pipe; write via {ExecHandle#stdin}
      #                  and close to send EOF. Only meaningful for the streaming
      #                  variants (which return an ExecHandle); a blocking
      #                  exec/shell collects to completion and has nowhere to hand
      #                  back the sink, so a piped process reading stdin would
      #                  block forever waiting for EOF — rejected there.
      #   a String     — fed as a fixed byte buffer (closed automatically).
      # An unrecognized Symbol is a loud error rather than being fed as its bytes
      # (so a typo'd or mistaken `stdin: :null`-style mode never silently sends
      # the literal characters of the mode name to the process).
      case stdin
      when nil, :null then nil
      when :pipe
        unless pipe_ok
          raise ArgumentError,
            "stdin: :pipe is only valid for exec_stream/shell_stream — a blocking " \
            "exec/shell cannot expose a writable stdin sink; pass a String to feed bytes"
        end
        opts["stdin_pipe"] = true
      when Symbol
        raise ArgumentError,
          "unknown stdin mode #{stdin.inspect}; expected nil or :null (no stdin), " \
          ":pipe (exec_stream/shell_stream only), or a String of bytes to feed"
      else
        bytes = String.try_convert(stdin) or
          raise TypeError, "stdin must be nil, :null, :pipe, or a String (got #{stdin.class})"
        opts["stdin"] = bytes
      end
      if rlimits
        opts["rlimits"] = rlimits.map do |resource, limit|
          soft, hard = limit.is_a?(Array) ? [limit[0], limit[1]] : [limit, limit]
          [resource.to_s, Integer(soft), Integer(hard)]
        end
      end
      opts
    end
  end

  # A streaming image-pull + create session, from {Sandbox.create_with_progress}.
  # Iterate it (it is {Enumerable}) to consume progress-event Hashes as the image
  # pulls, then call {#sandbox} to get the booted {Sandbox}. Each event Hash has a
  # "kind" key (e.g. "resolving", "resolved", "layer_download_progress",
  # "layer_materialize_progress", "complete") plus kind-specific fields.
  #
  # @example
  #   session = Microsandbox::Sandbox.create_with_progress("box", image: "python")
  #   session.each { |ev| puts "#{ev["kind"]} #{ev["downloaded_bytes"]}" }
  #   sb = session.sandbox
  #   begin
  #     sb.exec("python", ["-V"])
  #   ensure
  #     sb.stop
  #   end
  class PullSession
    include Enumerable

    def initialize(native)
      @native = native
    end

    # Yield each progress-event Hash until the pull finishes. Returns an
    # Enumerator when called without a block.
    # @yieldparam event [Hash]
    # @return [self, Enumerator]
    def each
      return enum_for(:each) unless block_given?

      while (event = @native.recv)
        yield event
      end
      self
    end

    # The booted sandbox. Joins the create task (draining any remaining pull
    # progress first), so call it after iterating progress. The returned
    # {Sandbox} is live — stop it when done. Memoized; callable once.
    # @return [Sandbox]
    def sandbox
      @sandbox ||= Sandbox.new(@native.result)
    end
  end
end
