# frozen_string_literal: true

module Microsandbox
  # Lightweight metadata about a sandbox, returned by {Sandbox.get} and
  # {Sandbox.list}. This is a snapshot, not a live handle.
  class SandboxInfo
    # @return [String]
    attr_reader :name
    # @return [Symbol] :running, :draining, :paused, :stopped, or :crashed
    attr_reader :status

    def initialize(data)
      @name = data["name"]
      @status = data["status"].to_sym
      @created_at_ms = data["created_at_ms"]
      @updated_at_ms = data["updated_at_ms"]
    end

    def running? = @status == :running
    def stopped? = @status == :stopped

    # @return [Time, nil]
    def created_at
      @created_at_ms && Time.at(@created_at_ms / 1000.0)
    end

    # @return [Time, nil]
    def updated_at
      @updated_at_ms && Time.at(@updated_at_ms / 1000.0)
    end

    def inspect
      "#<Microsandbox::SandboxInfo name=#{@name.inspect} status=#{@status}>"
    end
  end

  # The terminal observation of a stopped sandbox, returned by
  # {Sandbox#wait_until_stopped}. Mirrors the official SDKs' `SandboxStopResult`.
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
        "#{@exit_code ? " exit_code=#{@exit_code}" : ""}#{@signal ? " signal=#{@signal}" : ""}>"
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
      # @param network [String, Symbol, NetworkPolicy, Hash, nil] network policy.
      #   A preset name ("public_only" (default), "none", "allow_all",
      #   "non_local"), a {NetworkPolicy} (e.g. {NetworkPolicy.custom}), or a Hash
      #   describing a custom policy (`default_egress:`, `default_ingress:`,
      #   `rules:`, `deny_domains:`, `deny_domain_suffixes:`). See {NetworkPolicy}
      #   and {Rule}.
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
      # @param secrets [Array<Hash>, nil] placeholder-protected secrets, each
      #   { env:, value:, host: } — the value is substituted by the TLS proxy only
      #   for the allowed host (auto-enables TLS interception)
      # @param detached [Boolean] keep running after this process exits
      # @param replace [Boolean] replace an existing sandbox with the same name
      # @param replace_with_timeout [Numeric, nil] replace, waiting up to N seconds
      # @yieldparam sandbox [Sandbox]
      # @return [Sandbox, Object] the sandbox, or the block's return value
      def create(name,
                 image: nil, cpus: nil, memory: nil, env: nil, workdir: nil,
                 shell: nil, user: nil, hostname: nil, labels: nil, scripts: nil,
                 entrypoint: nil, ports: nil, ports_udp: nil, volumes: nil, network: nil,
                 patches: nil,
                 from_snapshot: nil, log_level: nil, quiet_logs: false, security: nil,
                 oci_upper_size: nil, max_duration: nil, idle_timeout: nil, rlimits: nil,
                 pull_policy: nil, registry_auth: nil, registry_insecure: false,
                 registry_ca_certs: nil, secrets: nil,
                 detached: false, replace: false, replace_with_timeout: nil)
        Microsandbox.ensure_runtime!
        opts = {}
        opts["image"] = image.to_s if image
        opts["from_snapshot"] = from_snapshot.to_s if from_snapshot
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
        opts["detached"] = true if detached
        if replace_with_timeout
          opts["replace_with_timeout"] = Float(replace_with_timeout)
        elsif replace
          opts["replace"] = true
        end

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

      # Restart a previously-defined sandbox by name.
      # @return [Sandbox]
      def start(name, detached: false)
        Microsandbox.ensure_runtime!
        new(Native::Sandbox.start(name.to_s, { "detached" => detached }))
      end

      # Fetch metadata for a sandbox by name.
      # @return [SandboxInfo]
      def get(name)
        SandboxInfo.new(Native::Sandbox.get(name.to_s))
      end

      # List all sandboxes.
      # @return [Array<SandboxInfo>]
      def list
        Native::Sandbox.list.map { |info| SandboxInfo.new(info) }
      end

      # List sandboxes carrying all of the given labels (AND-matched).
      # @param labels [Hash] required key => value labels
      # @return [Array<SandboxInfo>]
      def list_with(labels: {})
        opts = { "labels" => stringify(labels) }
        Native::Sandbox.list_with(opts).map { |info| SandboxInfo.new(info) }
      end

      # Remove a (stopped) sandbox by name.
      # @return [nil]
      def remove(name)
        Native::Sandbox.remove(name.to_s)
        nil
      end

      private

      def stringify(hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
      end

      def intify_ports(ports)
        ports.each_with_object({}) { |(k, v), acc| acc[Integer(k)] = Integer(v) }
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

      # Normalize secrets into [env, value, host] triples for the native layer.
      # Each entry is a Hash { env:, value:, host: } (string or symbol keys).
      def normalize_secrets(secrets)
        Array(secrets).map do |spec|
          env = spec[:env] || spec["env"]
          value = spec[:value] || spec["value"]
          host = spec[:host] || spec["host"]
          unless env && value && host
            raise ArgumentError, "secret spec needs :env, :value, and :host (got #{spec.inspect})"
          end
          [env.to_s, value.to_s, host.to_s]
        end
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

      # Normalize volumes (Hash of guest_path => spec) into [guest, kind, source]
      # triples for the native layer. A spec is a host path String (bind mount),
      # or a Hash { bind: "/host" } / { named: "volume-name" }.
      def normalize_volumes(volumes)
        volumes.map do |guest, spec|
          guest = guest.to_s
          case spec
          when String
            [guest, "bind", spec]
          when Hash
            if (named = spec[:named] || spec["named"])
              [guest, "named", named.to_s]
            elsif (bind = spec[:bind] || spec["bind"])
              [guest, "bind", bind.to_s]
            else
              raise ArgumentError, "volume spec for #{guest.inspect} needs :bind or :named"
            end
          else
            raise ArgumentError, "invalid volume spec for #{guest.inspect}: #{spec.inspect}"
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
      MetricsStream.new(@native.metrics_stream(Float(interval)))
    end

    # Stream captured logs as they appear.
    #
    # @param sources [Array<String,Symbol>, nil] filter by source
    #   ("stdout"/"stderr"/"output"/"system")
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

    # Gracefully stop the sandbox (and wait for it to terminate).
    # @param timeout [Numeric, nil] seconds to wait before SIGKILL
    # @return [nil]
    def stop(timeout: nil)
      @native.stop(timeout && Float(timeout))
      nil
    end

    # Force-kill the sandbox (SIGKILL).
    # @param timeout [Numeric, nil] seconds to wait
    # @return [nil]
    def kill(timeout: nil)
      @native.kill(timeout && Float(timeout))
      nil
    end

    # Send the graceful-shutdown request and return immediately, without waiting
    # for the sandbox to terminate. Pair with {#wait_until_stopped}.
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

    # Request a graceful drain and return immediately, without waiting.
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

    def exec_opts(cwd:, user:, env:, timeout:, tty:, stdin:, rlimits:, pipe_ok: false)
      opts = {}
      opts["cwd"] = cwd.to_s if cwd
      opts["user"] = user.to_s if user
      opts["env"] = env.each_with_object({}) { |(k, v), a| a[k.to_s] = v.to_s } if env
      opts["timeout"] = Float(timeout) if timeout
      opts["tty"] = true if tty
      # `stdin: :pipe` opens a streaming stdin pipe — write to it via
      # {ExecHandle#stdin} and close to send EOF. It is only meaningful for the
      # streaming variants (which return an ExecHandle); a blocking exec/shell
      # collects to completion and has nowhere to hand back the sink, so a piped
      # process that reads stdin would block forever waiting for EOF. Reject it
      # there. Any other truthy value is fed as a fixed byte buffer (closed
      # automatically). nil means no stdin.
      case stdin
      when nil then nil
      when :pipe
        unless pipe_ok
          raise ArgumentError,
                "stdin: :pipe is only valid for exec_stream/shell_stream — a blocking " \
                "exec/shell cannot expose a writable stdin sink; pass a String to feed bytes"
        end
        opts["stdin_pipe"] = true
      else opts["stdin"] = stdin.to_s
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
end
