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
      # @param network ["public_only", "none", nil] network mode (default public_only)
      # @param detached [Boolean] keep running after this process exits
      # @param replace [Boolean] replace an existing sandbox with the same name
      # @param replace_with_timeout [Numeric, nil] replace, waiting up to N seconds
      # @yieldparam sandbox [Sandbox]
      # @return [Sandbox, Object] the sandbox, or the block's return value
      def create(name,
                 image: nil, cpus: nil, memory: nil, env: nil, workdir: nil,
                 shell: nil, user: nil, hostname: nil, labels: nil, scripts: nil,
                 entrypoint: nil, ports: nil, volumes: nil, network: nil,
                 from_snapshot: nil, detached: false, replace: false,
                 replace_with_timeout: nil)
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
        opts["volumes"] = normalize_volumes(volumes) if volumes
        opts["network"] = network.to_s if network
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
    # @param stdin [String, nil] data to feed to stdin
    # @return [ExecOutput]
    def exec(command, args = [], cwd: nil, user: nil, env: nil, timeout: nil, tty: false, stdin: nil)
      ExecOutput.new(@native.exec(command.to_s, Array(args).map(&:to_s),
                                  exec_opts(cwd:, user:, env:, timeout:, tty:, stdin:)))
    end

    # Run a shell script (pipes, redirects, etc. allowed) and collect output.
    # @return [ExecOutput]
    def shell(script, cwd: nil, user: nil, env: nil, timeout: nil, tty: false, stdin: nil)
      ExecOutput.new(@native.shell(script.to_s,
                                   exec_opts(cwd:, user:, env:, timeout:, tty:, stdin:)))
    end

    # Run a command and stream its output as it arrives.
    # @return [ExecHandle]
    # @see ExecHandle
    def exec_stream(command, args = [], cwd: nil, user: nil, env: nil, timeout: nil, tty: false, stdin: nil)
      ExecHandle.new(@native.exec_stream(command.to_s, Array(args).map(&:to_s),
                                         exec_opts(cwd:, user:, env:, timeout:, tty:, stdin:)))
    end

    # Run a shell script and stream its output as it arrives.
    # @return [ExecHandle]
    def shell_stream(script, cwd: nil, user: nil, env: nil, timeout: nil, tty: false, stdin: nil)
      ExecHandle.new(@native.shell_stream(script.to_s,
                                          exec_opts(cwd:, user:, env:, timeout:, tty:, stdin:)))
    end

    # Guest filesystem operations.
    # @return [FS]
    def fs
      @fs ||= FS.new(@native)
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

    def inspect
      "#<Microsandbox::Sandbox name=#{name.inspect}>"
    end

    private

    def exec_opts(cwd:, user:, env:, timeout:, tty:, stdin:)
      opts = {}
      opts["cwd"] = cwd.to_s if cwd
      opts["user"] = user.to_s if user
      opts["env"] = env.each_with_object({}) { |(k, v), a| a[k.to_s] = v.to_s } if env
      opts["timeout"] = Float(timeout) if timeout
      opts["tty"] = true if tty
      opts["stdin"] = stdin.to_s if stdin
      opts
    end
  end
end
