# frozen_string_literal: true

require "socket"
require "json"

# Observe what the NATIVE layer serializes for a create call, offline: a loopback
# TCPServer plays the cloud API, captures the request body the core builds, and
# answers HTTP 500 so the call returns at once. Extracted from
# spec/unit/cloud_request_spec.rb so every option-mapping spec can use it.
module WireCapture
  PROXY_ENV_VARS = %w[
    HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy
  ].freeze

  class FakeCloudApi
    READ_TIMEOUT = 5
    attr_reader :request_line

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { serve }
    end

    def url = "http://127.0.0.1:#{@port}"

    def captured_json
      @thread.join(READ_TIMEOUT)
      @body && !@body.empty? && JSON.parse(@body)
    end

    def close
      @server.close unless @server.closed?
      @thread.kill unless @thread.join(1)
      nil
    rescue IOError, SystemCallError
      nil
    end

    private

    def serve
      sock = @server.accept
      head = +""
      until head.include?("\r\n\r\n")
        raise "timed out reading request head" unless IO.select([sock], nil, nil, READ_TIMEOUT)
        head << sock.readpartial(4096)
      end
      headers, body = head.split("\r\n\r\n", 2)
      @request_line = headers.lines.first.strip
      length = headers[/^content-length:\s*(\d+)/i, 1].to_i
      while body.bytesize < length
        raise "timed out reading request body" unless IO.select([sock], nil, nil, READ_TIMEOUT)
        body << sock.readpartial(length - body.bytesize)
      end
      @body = body
      sock.write("HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n" \
                 "Content-Length: 2\r\nConnection: close\r\n\r\n{}")
    rescue IOError, SystemCallError, RuntimeError
      nil
    ensure
      begin
        sock&.close
      rescue IOError, SystemCallError
        nil
      end
    end
  end

  # A cloud API that keeps its connections alive, for specs that care about
  # the client's connection pool (spec/unit/fork_safety_spec.rb). Unlike
  # FakeCloudApi it serves any number of HTTP/1.1 requests per connection and
  # never asks the client to close, so a reqwest client that made a request
  # holds an idle pooled connection afterwards. Every connection gets a number
  # in accept order, and every request is logged with it:
  #
  #   {seq: 3, conn: 2, port: 51234, line: "GET /v1/volumes HTTP/1.1", key: "k-child"}
  #
  # `GET /v1/volumes` answers one managed volume named "seq-<seq>", so a caller
  # can tell from the listing it got back which logged request served it.
  # Anything else gets a 404.
  class KeepAliveCloudApi
    READ_TIMEOUT = 5

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @lock = Mutex.new
      @log = []
      @sockets = []
      @threads = []
      @connections = 0
      @acceptor = Thread.new { accept_loop }
    end

    def url = "http://127.0.0.1:#{@port}"

    # A copy of the request log, oldest first.
    def requests = @lock.synchronize { @log.map(&:dup) }

    # Connections accepted so far.
    def connections = @lock.synchronize { @connections }

    def close
      @server.close unless @server.closed?
      @acceptor.join(1) || @acceptor.kill
      sockets, threads = @lock.synchronize { [@sockets.dup, @threads.dup] }
      sockets.each { |sock| sock.close unless sock.closed? }
      threads.each { |thread| thread.join(1) || thread.kill }
      nil
    rescue IOError, SystemCallError
      nil
    end

    private

    def accept_loop
      loop do
        sock = @server.accept
        conn = @lock.synchronize do
          @sockets << sock
          @connections += 1
        end
        thread = Thread.new { serve(sock, conn, sock.peeraddr[1]) }
        @lock.synchronize { @threads << thread }
      end
    rescue IOError, SystemCallError
      nil # listener closed
    end

    # Serve requests on one connection until the client closes it (an idle
    # pooled connection may sit here for the whole example).
    def serve(sock, conn, port)
      buffer = +""
      loop do
        until buffer.include?("\r\n\r\n")
          IO.select([sock])
          buffer << sock.readpartial(4096)
        end
        head, buffer = buffer.split("\r\n\r\n", 2)
        length = head[/^content-length:\s*(\d+)/i, 1].to_i
        while buffer.bytesize < length
          raise "timed out reading request body" unless IO.select([sock], nil, nil, READ_TIMEOUT)
          buffer << sock.readpartial(4096)
        end
        buffer = buffer.byteslice(length..) || +""
        line = head.lines.first.strip
        key = head[/^authorization:\s*Bearer\s+(\S+)/i, 1]
        seq = @lock.synchronize do
          @log << {seq: @log.size + 1, conn: conn, port: port, line: line, key: key}
          @log.size
        end
        sock.write(respond(line, seq))
      end
    rescue IOError, SystemCallError, RuntimeError # EOFError included: the client closed
      nil
    ensure
      begin
        sock.close unless sock.closed?
      rescue IOError, SystemCallError
        nil
      end
    end

    def respond(line, seq)
      status, body =
        if line.start_with?("GET /v1/volumes ")
          stamp = "2026-01-01T00:00:00Z"
          volume = {id: "vol-#{seq}", name: "seq-#{seq}", kind: "managed", status: "active",
                    created_at: stamp, updated_at: stamp}
          ["200 OK", JSON.generate([volume])]
        else
          ["404 Not Found", "{}"]
        end
      "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
    end
  end

  def with_proxy_env_cleared
    saved = PROXY_ENV_VARS.to_h { |name| [name, [ENV.key?(name), ENV[name]]] }
    PROXY_ENV_VARS.each { |name| ENV.delete(name) }
    ENV["NO_PROXY"] = ENV["no_proxy"] = "127.0.0.1,localhost"
    yield
  ensure
    saved&.each { |name, (present, value)| present ? ENV[name] = value : ENV.delete(name) }
  end

  # The create body the core put on the wire for these kwargs.
  def wire_create(**kwargs)
    api = FakeCloudApi.new
    with_proxy_env_cleared do
      Microsandbox.with_backend(:cloud, url: api.url, api_key: "test-key") do
        expect { Microsandbox::Sandbox.create("wire-probe", image: "python", **kwargs) }
          .to raise_error(Microsandbox::CloudHttpError)
      end
    end
    body = api.captured_json
    expect(body).to be_a(Hash), "the fake cloud API captured no create request"
    body
  ensure
    api&.close
  end

  # The error the core raises BEFORE any request when the cloud backend rejects
  # an option — itself proof that the ext applied the option to the builder.
  def wire_rejection(**kwargs)
    with_proxy_env_cleared do
      Microsandbox.with_backend(:cloud, url: "http://127.0.0.1:9", api_key: "test-key") do
        Microsandbox::Sandbox.create("wire-probe", image: "python", **kwargs)
      end
    end
    raise "expected the cloud backend to reject #{kwargs.keys.inspect}"
  rescue Microsandbox::UnsupportedError => e
    e
  end
end
