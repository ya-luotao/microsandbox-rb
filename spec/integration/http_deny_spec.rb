# frozen_string_literal: true

require "json"

# How a request the network policy denies is answered (runtime v0.7, the
# `http:` create option). Modeled on upstream's sdk/rust/tests/http_deny.rs:
# egress is denied by default with gateway DNS open, so the guest resolves the
# denied name and the denial lands at the gateway's proxy, which answers plain
# HTTP itself — nothing is dialed upstream.
RSpec.describe "HTTP deny response (real microVM)", :integration do
  let(:denied_host) { "example.com" }
  let(:policy) do
    Microsandbox::NetworkPolicy.custom(default_egress: :deny, rules: [Microsandbox::Rule.allow_dns])
  end

  # One raw HTTP/1.1 request through busybox nc (alpine has no curl); returns
  # [status line, body] — both empty when the connection closes unanswered.
  def request(sandbox)
    script = "printf 'GET / HTTP/1.1\\r\\nHost: #{denied_host}\\r\\nConnection: close\\r\\n\\r\\n' " \
             "| nc -w 15 #{denied_host} 80"
    raw = sandbox.shell(script).stdout.to_s
    head, body = raw.split("\r\n\r\n", 2)
    [head.to_s.lines.first.to_s.strip, body.to_s]
  end

  def with_sandbox(**opts)
    name = unique_sandbox_name("http-deny")
    Microsandbox::Sandbox.create(name, image: default_test_image, network: policy, replace: true, **opts) do |sb|
      yield sb
    end
  ensure
    begin
      Microsandbox::Sandbox.remove(name)
    rescue Microsandbox::Error
      nil
    end
  end

  it "answers a denied plain-HTTP request with a JSON 403 by default" do
    with_sandbox do |sb|
      status, body = request(sb)
      expect(status).to start_with("HTTP/1.1 403")
      error = JSON.parse(body)
      expect(error).to include("code" => "network_policy_denied", "domain" => denied_host,
        "message" => "Request blocked by network policy.")
    end
  end

  it "uses network_message: literally as the JSON message" do
    with_sandbox(http: {network_message: "blocked {host}: ask for access"}) do |sb|
      status, body = request(sb)
      expect(status).to start_with("HTTP/1.1 403")
      expect(JSON.parse(body)).to include("code" => "network_policy_denied",
        "message" => "blocked {host}: ask for access")
    end
  end

  it "answers with a text 403 for format: :text" do
    with_sandbox(http: {format: :text}) do |sb|
      status, body = request(sb)
      expect(status).to start_with("HTTP/1.1 403")
      expect { JSON.parse(body) }.to raise_error(JSON::ParserError)
      expect(body).not_to be_empty
    end
  end

  it "closes the connection without an HTTP answer for deny_response: false" do
    with_sandbox(http: {deny_response: false}) do |sb|
      status, body = request(sb)
      expect(status).not_to start_with("HTTP/")
      expect(body).to be_empty
    end
  end
end
