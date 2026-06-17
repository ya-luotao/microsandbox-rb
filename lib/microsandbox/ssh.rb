# frozen_string_literal: true

module Microsandbox
  # The result of an {SshClient#exec} call. Like {ExecOutput}, `stdout`/`stderr`
  # are the captured bytes decoded as UTF-8 (lenient); use `stdout_bytes`/
  # `stderr_bytes` for the raw ASCII-8BIT bytes.
  class SshOutput
    # @return [Integer] the remote command's exit status
    attr_reader :status
    # @return [String] raw stdout bytes (ASCII-8BIT)
    attr_reader :stdout_bytes
    # @return [String] raw stderr bytes (ASCII-8BIT)
    attr_reader :stderr_bytes

    def initialize(data)
      @status = data["status"]
      @success = data["success"]
      @stdout_bytes = data["stdout"]
      @stderr_bytes = data["stderr"]
    end

    # @return [Boolean] whether the command exited with status 0
    def success? = @success

    # @return [Boolean] whether the command exited non-zero
    def failure? = !@success

    # @return [String] stdout decoded as UTF-8
    def stdout
      @stdout ||= @stdout_bytes.dup.force_encoding(Encoding::UTF_8)
    end

    # @return [String] stderr decoded as UTF-8
    def stderr
      @stderr ||= @stderr_bytes.dup.force_encoding(Encoding::UTF_8)
    end

    def to_s = stdout

    def inspect
      "#<Microsandbox::SshOutput status=#{@status} success=#{@success} " \
        "stdout=#{stdout.bytesize}B stderr=#{stderr.bytesize}B>"
    end
  end

  # A high-level SFTP session over an {SshClient}, from {SshClient#sftp}. All
  # paths are guest paths. Mirrors the `SftpClient` of the official SDKs.
  class SftpClient
    def initialize(native)
      @native = native
    end

    # Read a file's full contents.
    # @return [String] raw bytes (ASCII-8BIT)
    def read(path)
      @native.read(path.to_s)
    end

    # Read a file and decode it as UTF-8 (lenient).
    # @return [String]
    def read_text(path)
      read(path).force_encoding(Encoding::UTF_8)
    end

    # Write a file, creating or truncating it.
    # @return [nil]
    def write(path, data)
      @native.write(path.to_s, data.to_s)
      nil
    end

    # Create a directory.
    # @return [nil]
    def mkdir(path)
      @native.mkdir(path.to_s)
      nil
    end

    # Remove a file.
    # @return [nil]
    def remove_file(path)
      @native.remove_file(path.to_s)
      nil
    end

    # Remove an empty directory.
    # @return [nil]
    def remove_dir(path)
      @native.remove_dir(path.to_s)
      nil
    end

    # Rename (move) a file or directory.
    # @return [nil]
    def rename(old_path, new_path)
      @native.rename(old_path.to_s, new_path.to_s)
      nil
    end

    # Create a symlink at +link_path+ pointing to +target+.
    # @return [nil]
    def symlink(target, link_path)
      @native.symlink(target.to_s, link_path.to_s)
      nil
    end

    # Resolve a path to its canonical absolute form.
    # @return [String]
    def real_path(path)
      @native.real_path(path.to_s)
    end

    # Read a symlink's target.
    # @return [String]
    def read_link(path)
      @native.read_link(path.to_s)
    end

    # Close the SFTP session. Idempotent.
    # @return [nil]
    def close
      @native.close
      nil
    end
  end

  # A native, in-process SSH client session to a sandbox, from
  # {SshOps#open_client}. Mirrors the `SshClient` of the official SDKs.
  #
  # @example
  #   sb.ssh.open_client do |client|
  #     out = client.exec("uname -a")
  #     puts out.stdout
  #   end
  class SshClient
    def initialize(native)
      @native = native
    end

    # Run a command over SSH and collect its output.
    # @param command [String] the command line (interpreted by the remote shell)
    # @param tty [Boolean] allocate a pseudo-terminal
    # @return [SshOutput]
    def exec(command, tty: false)
      SshOutput.new(@native.exec(command.to_s, tty ? true : false))
    end

    # Attach the local terminal to an interactive SSH shell. Host-TTY coupled
    # (puts the terminal in raw mode and forwards SIGWINCH); blocks until the
    # remote shell exits or the detach sequence is typed.
    # @param term [String, nil] TERM value to request (defaults to $TERM)
    # @param detach_keys [String, nil] detach key sequence (e.g. "ctrl-p,ctrl-q")
    # @return [Integer] the remote shell's exit status
    def attach(term: nil, detach_keys: nil)
      @native.attach(term&.to_s, detach_keys&.to_s)
    end

    # Open an SFTP session over this connection. With a block, the session is
    # yielded and closed when the block returns.
    # @yieldparam sftp [SftpClient]
    # @return [SftpClient, Object]
    def sftp
      session = SftpClient.new(@native.sftp)
      return session unless block_given?

      begin
        yield session
      ensure
        session.close
      end
    end

    # Close the SSH client session. Idempotent.
    # @return [nil]
    def close
      @native.close
      nil
    end
  end

  # A reusable SSH server endpoint for a sandbox, from {SshOps#prepare_server}.
  # Each {#serve_connection} serves a single SSH transport over this process's
  # stdin/stdout — typically wired up by a parent SSH daemon via `ForceCommand`
  # or an inetd-style spawn. Mirrors the `SshServer` of the official SDKs.
  class SshServer
    def initialize(native)
      @native = native
    end

    # Serve one SSH connection over this process's stdin/stdout. Blocks until
    # the session ends.
    # @return [nil]
    def serve_connection
      @native.serve_connection
      nil
    end

    # Release the prepared server endpoint. Idempotent.
    # @return [nil]
    def close
      @native.close
      nil
    end
  end

  # The SSH namespace for a sandbox, returned by {Sandbox#ssh}. Use it to open a
  # native in-process SSH client or prepare a reusable server endpoint.
  class SshOps
    def initialize(native)
      @native = native
    end

    # Open a native in-process SSH client to the sandbox. With a block, the
    # client is yielded and closed when the block returns.
    # @param user [String] guest user to authenticate as (default "root")
    # @param term [String, nil] TERM value for the session
    # @param sftp [Boolean] enable the SFTP subsystem (default true)
    # @yieldparam client [SshClient]
    # @return [SshClient, Object]
    def open_client(user: "root", term: nil, sftp: true)
      opts = { "user" => user.to_s, "sftp" => sftp ? true : false }
      opts["term"] = term.to_s if term
      client = SshClient.new(@native.ssh_open_client(opts))
      return client unless block_given?

      begin
        yield client
      ensure
        client.close
      end
    end

    # Prepare a reusable SSH server endpoint for the sandbox.
    # @param host_key_path [String, nil] PEM host key path (generated if omitted)
    # @param authorized_keys_path [String, nil] authorized_keys file path
    # @param user [String, nil] guest user connections run as
    # @param sftp [Boolean] enable the SFTP subsystem (default true)
    # @return [SshServer]
    def prepare_server(host_key_path: nil, authorized_keys_path: nil, user: nil, sftp: true)
      opts = { "sftp" => sftp ? true : false }
      opts["host_key_path"] = host_key_path.to_s if host_key_path
      opts["authorized_keys_path"] = authorized_keys_path.to_s if authorized_keys_path
      opts["user"] = user.to_s if user
      SshServer.new(@native.ssh_prepare_server(opts))
    end
  end
end
