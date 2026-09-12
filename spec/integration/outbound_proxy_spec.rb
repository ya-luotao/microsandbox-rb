# frozen_string_literal: true

require "socket"

# Real-microVM coverage for the `proxy:` create option (runtime v0.6.17,
# upstream #1234 / #1507). Opt-in via MICROSANDBOX_INTEGRATION=1. Mirrors the
# shape of upstream `sdk/rust/tests/outbound_proxy.rs`: an in-process minimal
# SOCKS server on the host loopback records the handshake and the CONNECT
# target, then answers the tunnelled HTTP request itself, so the assertion is
# end-to-end (guest `wget` → host network stack → SOCKS proxy → HTTP body)
# without any external network.
#
# The proxy is dialed by the host-side network stack, so `127.0.0.1` is the
# host's loopback (exactly as in the upstream Rust test). The HTTP *target* is a
# TEST-NET-2 address (198.51.100.10, the same block upstream uses): it is
# classified public, so the default egress policy admits it, and nothing ever
# actually connects to it — the fake proxy consumes the CONNECT.
module OutboundProxySpec
  # Minimal single-connection SOCKS4/SOCKS5 server (CONNECT only) that then
  # serves one HTTP/1.0 response over the tunnel.
  class FakeSocksServer
    BODY = "proxied-ok"
    PASSWORD_ENV = "MSB_RB_SPEC_SOCKS5_PASSWORD"

    attr_reader :port, :target, :user_id, :username, :password, :error

    # @param version [4, 5]
    # @param credentials [Array(String, String), nil] SOCKS5 username/password
    #   to require (nil: only the no-auth method is offered)
    def initialize(version:, credentials: nil)
      @version = version
      @credentials = credentials
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { serve }
    end

    def address = "127.0.0.1:#{@port}"

    # Wait for the single proxied session to finish; raises the server-side
    # failure (if any) so a protocol mismatch surfaces as its own message.
    def join(timeout = 30)
      unless @thread.join(timeout)
        @thread.kill
        raise "SOCKS#{@version} fixture saw no complete session within #{timeout}s"
      end
      raise error if error
    ensure
      @server.close unless @server.closed?
    end

    private

    def serve
      sock = @server.accept
      (@version == 5) ? socks5(sock) : socks4(sock)
      http(sock)
    rescue => e
      @error = e
    ensure
      sock&.close
    end

    # RFC 1928 greeting/method selection (+ RFC 1929 username/password), CONNECT.
    def socks5(sock)
      ver, nmethods = sock.read(2).unpack("CC")
      raise "unexpected SOCKS version #{ver}" unless ver == 5
      methods = sock.read(nmethods).unpack("C*")
      if @credentials
        raise "client did not offer username/password auth (#{methods})" unless methods.include?(2)
        sock.write([5, 2].pack("CC"))
        auth_ver = sock.read(1).unpack1("C")
        raise "bad auth version #{auth_ver}" unless auth_ver == 1
        @username = sock.read(sock.read(1).unpack1("C"))
        @password = sock.read(sock.read(1).unpack1("C"))
        ok = [@username, @password] == @credentials
        sock.write([1, ok ? 0 : 1].pack("CC"))
        raise "wrong SOCKS5 credentials #{@username.inspect}" unless ok
      else
        raise "client did not offer no-auth (#{methods})" unless methods.include?(0)
        sock.write([5, 0].pack("CC"))
      end
      ver, cmd, _rsv, atyp = sock.read(4).unpack("CCCC")
      raise "unexpected request #{[ver, cmd].inspect}" unless ver == 5 && cmd == 1
      host = case atyp
      when 1 then sock.read(4).unpack("C4").join(".")
      when 3 then sock.read(sock.read(1).unpack1("C"))
      when 4 then sock.read(16).unpack("n8").map { |h| h.to_s(16) }.join(":")
      else raise "unexpected ATYP #{atyp}"
      end
      port = sock.read(2).unpack1("n")
      @target = [host, port]
      # Succeeded, bound address 0.0.0.0:0.
      sock.write([5, 0, 0, 1, 0, 0, 0, 0, 0].pack("C4C4n").b)
    end

    # SOCKS4 CONNECT: VN=4 CD=1 DSTPORT DSTIP USERID NUL.
    def socks4(sock)
      vn, cd, port = sock.read(4).unpack("CCn")
      raise "unexpected SOCKS4 request #{[vn, cd].inspect}" unless vn == 4 && cd == 1
      host = sock.read(4).unpack("C4").join(".")
      @user_id = sock.gets("\0").chomp("\0")
      @target = [host, port]
      sock.write([0, 0x5a, 0, 0, 0, 0, 0].pack("CCnC4").b)
    end

    def http(sock)
      request = +""
      until request.end_with?("\r\n\r\n")
        chunk = sock.readpartial(4096)
        request << chunk
      end
      raise "not an HTTP request: #{request.lines.first.inspect}" unless request.start_with?("GET ")
      sock.write(
        "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n" \
        "Content-Length: #{BODY.bytesize}\r\nConnection: close\r\n\r\n#{BODY}"
      )
    end
  end
end

RSpec.describe "outbound proxy", :integration do
  let(:image) { default_test_image }
  let(:target_ip) { "198.51.100.10" }
  let(:target_port) { 8080 }
  let(:fetch) { "wget -qO- -T 15 http://#{target_ip}:#{target_port}/probe" }

  # Assert the guest side FIRST so a denied/timed-out fetch reports wget's
  # stderr (plus whatever the fixture saw) instead of waiting out the fixture's
  # join timeout and failing with its generic message.
  def assert_proxied(sb, server)
    out = sb.shell(fetch)
    expect(out).to be_success,
      "guest fetch failed with status #{out.exit_code.inspect}: #{out.stderr.inspect}; " \
      "proxy fixture error: #{server.error.inspect}"
    expect(out.stdout).to eq(OutboundProxySpec::FakeSocksServer::BODY)
    server.join
    expect(server.target).to eq([target_ip, target_port])
  end

  it "routes guest TCP egress through an unauthenticated SOCKS5 proxy" do
    server = OutboundProxySpec::FakeSocksServer.new(version: 5)
    Microsandbox::Sandbox.create(
      unique_sandbox_name, image: image,
      proxy: Microsandbox::OutboundProxy.socks5(server.address)
    ) do |sb|
      assert_proxied(sb, server)
      expect(server.username).to be_nil
    end
  end

  it "authenticates to a SOCKS5 proxy with a username and an env-backed password" do
    server = OutboundProxySpec::FakeSocksServer.new(version: 5, credentials: ["sandbox", "proxy-password"])
    ENV[OutboundProxySpec::FakeSocksServer::PASSWORD_ENV] = "proxy-password"
    begin
      proxy = Microsandbox::OutboundProxy.socks5(server.address)
        .credentials("sandbox", Microsandbox::SecretSource.env(OutboundProxySpec::FakeSocksServer::PASSWORD_ENV))
      Microsandbox::Sandbox.create(unique_sandbox_name, image: image, proxy: proxy) do |sb|
        assert_proxied(sb, server)
        expect(server.username).to eq("sandbox")
        expect(server.password).to eq("proxy-password")
      end
    ensure
      ENV.delete(OutboundProxySpec::FakeSocksServer::PASSWORD_ENV)
    end
  end

  it "routes guest TCP egress through a SOCKS4 proxy, sending the user_id (Hash form)" do
    server = OutboundProxySpec::FakeSocksServer.new(version: 4)
    Microsandbox::Sandbox.create(
      unique_sandbox_name, image: image,
      proxy: {protocol: :socks4, address: server.address, user_id: "rb-spec"}
    ) do |sb|
      assert_proxied(sb, server)
      expect(server.user_id).to eq("rb-spec")
    end
  end

  # The core reports this as a NetworkBuilder(InvalidOutboundProxy) error; the
  # ext routes that variant to InvalidConfigError (a malformed address is a
  # config mistake, not a policy one) while other builder errors stay
  # NetworkPolicyError.
  it "rejects an unparseable proxy address at create time without booting" do
    expect do
      Microsandbox::Sandbox.create(
        unique_sandbox_name, image: image,
        proxy: Microsandbox::OutboundProxy.socks5("not-an-ip-port")
      )
    end.to raise_error(Microsandbox::InvalidConfigError, /invalid SOCKS5 proxy address/)
  end
end
