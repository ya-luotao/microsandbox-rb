# frozen_string_literal: true

module Microsandbox
  # A single event from a streaming execution ({Sandbox#exec_stream}).
  class ExecEvent
    # @return [Symbol] :started, :stdout, :stderr, :exited, :failed, or :stdin_error
    attr_reader :type
    # @return [Integer, nil] pid (for :started)
    attr_reader :pid
    # @return [Integer, nil] exit code (:exited) or errno (:failed/:stdin_error)
    attr_reader :code
    # @return [String, nil] raw bytes (ASCII-8BIT) for :stdout/:stderr, or the
    #   message for :failed/:stdin_error
    attr_reader :data

    def initialize(event)
      @type = event["type"].to_sym
      @pid = event["pid"]
      @code = event["code"]
      @data = event["data"]
    end

    # @return [String, nil] {#data} decoded as UTF-8 (lossy — invalid byte
    #   sequences are replaced with U+FFFD, so the result is always valid UTF-8)
    def text
      @data&.dup&.force_encoding(Encoding::UTF_8)&.scrub
    end

    def started? = @type == :started
    def stdout? = @type == :stdout
    def stderr? = @type == :stderr
    def exited? = @type == :exited
    def failed? = @type == :failed
    def stdin_error? = @type == :stdin_error

    def inspect
      "#<Microsandbox::ExecEvent type=#{@type}#{" pid=#{@pid}" if @pid}" \
        "#{" code=#{@code}" if @code}#{" data=#{@data.bytesize}B" if @data}>"
    end
  end

  # The terminal status of a streamed execution ({ExecHandle#wait}) or of a
  # sandbox process ({Sandbox#wait}, {Sandbox#stop_and_wait}).
  class ExitStatus
    # @return [Integer, nil] the exit code, or nil when the process was
    #   terminated by a signal and so carries no code (e.g. a SIGKILL'd sandbox
    #   from {Sandbox#kill} then {Sandbox#wait}) — check {#success?} in that case.
    attr_reader :exit_code

    def initialize(data)
      @exit_code = data["exit_code"]
      @success = data["success"]
    end

    def success? = @success
    def failure? = !@success
  end

  # A writer for a streamed process's stdin, from {ExecHandle#stdin}.
  class ExecStdin
    def initialize(native)
      @native = native
    end

    # Write data to the process stdin.
    # @param data [String] raw bytes to write (binary-safe)
    # @raise [TypeError] if +data+ is not a String
    # @return [self]
    def write(data)
      bytes = Microsandbox.coerce_write_bytes(data)
      @native.write(bytes)
      self
    end

    # Send EOF.
    # @return [nil]
    def close
      @native.close
      nil
    end
  end

  # A live, streaming command execution, returned by {Sandbox#exec_stream} and
  # {Sandbox#shell_stream}.
  #
  # Iterate it (it is {Enumerable}) to consume {ExecEvent}s as they arrive, or
  # call {#collect} to drain it into an {ExecOutput}.
  #
  # @note **Single-pass, forward-only, single-consumer.** `each`/`collect` drain
  #   a one-shot native event channel, so the handle is *not* rewindable: a
  #   second `each`, or `collect` after a partial `each` (and vice versa),
  #   yields only what is left. Consume it once, from one thread. (An
  #   out-of-band {#kill}/{#signal} via the control channel is the exception —
  #   it can unblock a parked `each` from another thread.)
  #
  # @example
  #   handle = sb.exec_stream("python", ["-u", "script.py"])
  #   handle.each do |event|
  #     print event.text if event.stdout? || event.stderr?
  #   end
  class ExecHandle
    include Enumerable

    def initialize(native)
      @native = native
    end

    # @return [String] the correlation id for this execution
    def id
      @native.id
    end

    # Yield each {ExecEvent} until the stream ends. Returns an Enumerator when
    # called without a block.
    # @yieldparam event [ExecEvent]
    # @return [self, Enumerator]
    def each
      return enum_for(:each) unless block_given?

      while (event = @native.recv)
        yield ExecEvent.new(event)
      end
      self
    end

    # Block until the process exits.
    # @return [ExitStatus]
    def wait
      ExitStatus.new(@native.wait)
    end

    # Drain the stream and collect all output.
    # @return [ExecOutput]
    def collect
      ExecOutput.new(@native.collect)
    end

    # Send a signal (integer) to the running process.
    # @return [nil]
    def signal(sig)
      @native.signal(Integer(sig))
      nil
    end

    # Kill the running process (SIGKILL).
    # @return [nil]
    def kill
      @native.kill
      nil
    end

    # Resize the pseudo-terminal (only meaningful when started with tty: true).
    # @return [nil]
    def resize(rows, cols)
      @native.resize(Integer(rows), Integer(cols))
      nil
    end

    # The stdin writer, or nil if stdin was not piped. Returned only once.
    # @return [ExecStdin, nil]
    def stdin
      return @stdin if defined?(@stdin)

      native_sink = @native.take_stdin
      @stdin = native_sink && ExecStdin.new(native_sink)
    end
  end
end
