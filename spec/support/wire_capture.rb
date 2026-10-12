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
