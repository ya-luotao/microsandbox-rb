# frozen_string_literal: true

module Microsandbox
  # A single raw agent-protocol frame: a correlation id, flag bits, and a
  # CBOR-encoded body. Decode {#body} with a CBOR library of your choice.
  class AgentFrame
    # @return [Integer] correlation id from the frame header
    attr_reader :id
    # @return [Integer] flag bits (see {AgentClient::FLAG_TERMINAL} etc.)
    attr_reader :flags
    # @return [String] raw CBOR body bytes (ASCII-8BIT)
    attr_reader :body

    def initialize(data)
      @id = data["id"]
      @flags = data["flags"]
      @body = data["body"]
    end

    # @return [Boolean] last frame of a stream
    def terminal? = (@flags & AgentClient::FLAG_TERMINAL) != 0

    # @return [Boolean] opens a new session
    def session_start? = (@flags & AgentClient::FLAG_SESSION_START) != 0

    # @return [Boolean] connection-shutdown signal
    def shutdown? = (@flags & AgentClient::FLAG_SHUTDOWN) != 0

    def inspect
      "#<Microsandbox::AgentFrame id=#{@id} flags=0x#{@flags.to_s(16)} body=#{@body&.bytesize}B>"
    end
  end

  # An open raw agent stream, from {AgentClient#stream}. {Enumerable}: iterate to
  # consume {AgentFrame}s until the stream ends (the terminal frame is delivered,
  # then iteration stops). Mirrors the official SDKs' `AgentStream`.
  #
  # @note **Single-pass, forward-only, single-consumer.** `each` drains a
  #   one-shot native channel — not rewindable, iterate once from a single
  #   thread; a second pass or a post-drain combinator yields nothing.
  #
  # @example
  #   stream = client.stream(0, request_body)
  #   stream.each { |frame| handle(frame) }
  class AgentStream
    include Enumerable

    # @return [Integer] the protocol correlation id (pass to {AgentClient#send_frame})
    attr_reader :id

    def initialize(native, id, handle)
      @native = native
      @id = id
      @handle = handle
    end

    # Pull the next frame, or nil at end-of-stream.
    # @return [AgentFrame, nil]
    def recv
      frame = @native.stream_next(@handle)
      frame && AgentFrame.new(frame)
    end

    # @yieldparam frame [AgentFrame]
    # @return [self, Enumerator]
    def each
      return enum_for(:each) unless block_given?

      while (frame = recv)
        yield frame
      end
      self
    end

    # Close the stream and release its handle. Idempotent.
    # @return [nil]
    def close
      @native.stream_close(@handle)
      nil
    end
  end

  # A low-level **raw agent client** — the byte-level transport to a sandbox's
  # `agentd` over its relay socket. This is the rawest tier of the SDK: it moves
  # CBOR-encoded protocol frames in and out; encoding/decoding the bodies is up
  # to you. Most users want {Sandbox#exec}/{Sandbox#fs} instead; reach for this
  # to drive `agentd` protocol features the high-level API does not expose, or to
  # bridge the relay socket to another transport (see {socket_path}).
  #
  # Mirrors the `AgentClient` in the official Python/Node/Go SDKs.
  #
  # @example one-shot request/response
  #   Microsandbox::AgentClient.connect_sandbox("my-box") do |client|
  #     frame = client.request(0, cbor_encoded_request)
  #     handle(frame.body)
  #   end
  class AgentClient
    # Frame flag bits (mirror the protocol constants in the other SDKs).
    FLAG_TERMINAL = 0b0000_0001
    FLAG_SESSION_START = 0b0000_0010
    FLAG_SHUTDOWN = 0b0000_0100

    class << self
      # Connect to a running sandbox by name (max 128 UTF-8 bytes). With a block,
      # the client is yielded and closed when the block returns.
      # @param name [String]
      # @param timeout [Numeric, nil] handshake timeout in seconds. nil (the
      #   default) uses the core default (~10s); 0 fails fast (an immediate
      #   deadline); a negative or non-finite value raises {Error}.
      # @yieldparam client [AgentClient]
      # @return [AgentClient, Object]
      def connect_sandbox(name, timeout: nil, &block)
        wrap(Native::AgentClient.connect_sandbox(name.to_s, timeout && Float(timeout)), &block)
      end

      # Connect to an agentd relay socket by path. See {connect_sandbox}.
      # @return [AgentClient, Object]
      def connect_path(path, timeout: nil, &block)
        wrap(Native::AgentClient.connect_path(path.to_s, timeout && Float(timeout)), &block)
      end

      # Resolve a sandbox's agent relay socket path **without** connecting — the
      # same path {connect_sandbox} would dial. Useful for bridging the socket to
      # another byte transport. The sandbox need not be running.
      # @return [String]
      def socket_path(name)
        Native::AgentClient.socket_path(name.to_s)
      end

      private

      def wrap(native, &block)
        client = new(native)
        return client unless block

        begin
          block.call(client)
        ensure
          client.close
        end
      end
    end

    def initialize(native)
      @native = native
    end

    # Send one frame and await a single response frame.
    # @param flags [Integer] frame flag bits
    # @param body [String] CBOR-encoded body bytes
    # @return [AgentFrame]
    def request(flags, body)
      AgentFrame.new(@native.request(Integer(flags), body.to_s))
    end

    # Open a streaming session.
    # @param flags [Integer]
    # @param body [String]
    # @return [AgentStream]
    def stream(flags, body)
      opened = @native.stream_open(Integer(flags), body.to_s)
      AgentStream.new(@native, opened["id"], opened["handle"])
    end

    # Send a follow-up frame on an existing correlation id (e.g. a stream's
    # {AgentStream#id}). Named +send_frame+ rather than +send+ so it does not
    # shadow Ruby's `Object#send`. Maps to the protocol "send" in the other SDKs.
    # @return [nil]
    def send_frame(id, flags, body)
      @native.send(Integer(id), Integer(flags), body.to_s)
      nil
    end

    # The cached handshake `core.ready` frame body (CBOR bytes).
    # @return [String]
    def ready_bytes
      @native.ready_bytes
    end

    # Close the connection. Idempotent.
    # @return [nil]
    def close
      @native.close
      nil
    end
  end
end
