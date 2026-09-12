# frozen_string_literal: true

require "socket"
require "json"

# Observe what the NATIVE layer actually puts on the wire for a create option,
# without a runtime and without the network: a loopback TCPServer plays the
# cloud API, captures the create request body the core serializes, and answers
# with an HTTP error so the call returns immediately. This goes one step past
# the stubbed-native option-mapping specs in sandbox_spec.rb — those prove the
# Ruby hash; this proves the ext applied it to the core's builder (a missing
# native guard/setter leaves the field at its default and fails here).
#
# Hermetic: 127.0.0.1:0, bounded reads, the server is closed in `ensure`, and
# the ambient proxy environment is neutralized around the call — reqwest
# auto-detects the system proxy (HTTP_PROXY / ALL_PROXY, honouring NO_PROXY)
# when the cloud client is built inside `with_backend`, so without that an
# `HTTP_PROXY` in the developer's or CI's environment would route the loopback
# request through the proxy (fixture sees nothing; a remote proxy would even
# receive the synthetic body). `with_proxy_env_cleared` clears every proxy
# variable, sets NO_PROXY/no_proxy to loopback, and restores each variable's
# exact prior presence/value afterwards.
# The cloud backend accepts http:// URLs (upstream tests use
# http://127.0.0.1:8080), and its first network activity is the create POST,
# so the captured body is the same one a real API would receive.
module CloudRequestSpec
  # Every variable reqwest's system-proxy detection consults (both spellings).
  PROXY_ENV_VARS = %w[
    HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy
  ].freeze

  class FakeCloudApi
    READ_TIMEOUT = 5

    attr_reader :port

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @request_line = nil
      @body = nil
      @closed = false
      @thread = Thread.new { serve }
    end

    def url = "http://127.0.0.1:#{@port}"

    # Parsed JSON body of the single captured request (nil if none arrived).
    def captured_json
      @thread.join(READ_TIMEOUT)
      @body && JSON.parse(@body)
    end

    attr_reader :request_line

    # Idempotent, never raises.
    def close
      return if @closed
      @closed = true
      begin
        @server.close unless @server.closed?
      rescue IOError, SystemCallError
        # already closed
      end
      @thread.kill unless @thread.join(1)
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
      # Any HTTP error works: the client surfaces it as CloudHttpError and the
      # example only cares about what was sent.
      sock.write(
        "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n" \
        "Content-Length: 2\r\nConnection: close\r\n\r\n{}"
      )
    rescue IOError, SystemCallError, RuntimeError
      # listener closed / peer gone: the example's assertion reports the gap
    ensure
      begin
        sock&.close
      rescue IOError, SystemCallError
        # already closed
      end
    end
  end
end

RSpec.describe "create request as serialized by the native layer" do
  # Run the block with no ambient HTTP proxy and loopback excluded from
  # proxying, restoring every variable to exactly its prior state (present with
  # the same value, or absent) in `ensure`. The client is constructed inside the
  # block (`with_backend`), which is when reqwest reads these.
  def with_proxy_env_cleared
    saved = CloudRequestSpec::PROXY_ENV_VARS.to_h { |name| [name, [ENV.key?(name), ENV[name]]] }
    CloudRequestSpec::PROXY_ENV_VARS.each { |name| ENV.delete(name) }
    ENV["NO_PROXY"] = ENV["no_proxy"] = "127.0.0.1,localhost"
    yield
  ensure
    saved&.each do |name, (present, value)|
      present ? ENV[name] = value : ENV.delete(name)
    end
  end

  # Capture the create body for the given create kwargs against the fake API.
  def capture_create(**kwargs)
    api = CloudRequestSpec::FakeCloudApi.new
    with_proxy_env_cleared do
      Microsandbox.with_backend(:cloud, url: api.url, api_key: "test-key") do
        expect { Microsandbox::Sandbox.create("wire-probe", image: "python", **kwargs) }
          .to raise_error(Microsandbox::CloudHttpError, /cloud HTTP 500: POST \/v1\/sandboxes/)
      end
    end
    body = api.captured_json
    expect(body).not_to be_nil, "the fake cloud API captured no create request"
    expect(api.request_line).to start_with("POST /v1/sandboxes")
    body
  ensure
    api&.close
  end

  describe "strict: (v0.6.18)" do
    it "serializes network.strict == true when strict: is the ONLY advanced network option" do
      body = capture_create(strict: true)
      expect(body.dig("network", "strict")).to be(true)
      # And nothing else opened the advanced-network block for it: no sibling
      # option was sent (mirrors the normalization-layer example in
      # sandbox_spec.rb, but observed after the ext applied it).
      expect(body["network"].keys).not_to include("dns", "max_connections")
    end

    it "serializes network.strict == false for an explicit strict: false, via the network block" do
      body = capture_create(strict: false)
      expect(body.dig("network", "strict")).to be(false)
      # `false` is also the core default, so on its own it cannot tell an applied
      # setter from a skipped one. Entering the builder's network block is what
      # materializes the resolved policy into the request (the core serializes
      # the full local network config once `network(|n| ...)` runs); its
      # presence is the evidence that `strict: false` reached the block.
      expect(body["network"]).to have_key("policy")
    end

    it "leaves the network block untouched when strict: is omitted (baseline for the above)" do
      body = capture_create
      expect(body["network"]).to eq("enabled" => true, "strict" => false)
    end
  end
end
