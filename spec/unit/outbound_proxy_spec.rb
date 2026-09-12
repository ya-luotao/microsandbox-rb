# frozen_string_literal: true

# Pure-Ruby coverage of the `proxy:` create option (runtime v0.6.17): the
# OutboundProxy / SecretSource value objects, Hash coercion, and the validation
# rules mirrored from the Python SDK's OutboundProxy.__post_init__. The wire
# shape asserted here is the Python `_to_dict()` form the native layer parses.
RSpec.describe Microsandbox::OutboundProxy do
  let(:env_source) { Microsandbox::SecretSource.env("PROXY_PASSWORD") }

  describe ".socks4" do
    it "builds the wire hash without user_id when none is given" do
      proxy = described_class.socks4("127.0.0.1:1080")
      expect(proxy).to be_socks4
      expect(proxy.to_h).to eq("protocol" => "socks4", "address" => "127.0.0.1:1080")
    end

    it "carries an optional user_id" do
      proxy = described_class.socks4("127.0.0.1:1080", user_id: "ci")
      expect(proxy.user_id).to eq("ci")
      expect(proxy.to_h).to eq(
        "protocol" => "socks4", "address" => "127.0.0.1:1080", "user_id" => "ci"
      )
    end

    it "rejects credentials (SOCKS5-only)" do
      expect { described_class.socks4("127.0.0.1:1080").credentials("u", env_source) }
        .to raise_error(ArgumentError, /credentials are only supported for SOCKS5/)
    end
  end

  describe ".socks5" do
    it "builds the unauthenticated wire hash" do
      proxy = described_class.socks5("10.0.0.5:1080")
      expect(proxy).to be_socks5
      expect(proxy.username).to be_nil
      expect(proxy.password).to be_nil
      expect(proxy.to_h).to eq("protocol" => "socks5", "address" => "10.0.0.5:1080")
    end

    it "#credentials returns a NEW proxy carrying username + env password source" do
      base = described_class.socks5("10.0.0.5:1080")
      authed = base.credentials("sandbox", env_source)

      expect(authed).not_to equal(base)
      expect(base.to_h).to eq("protocol" => "socks5", "address" => "10.0.0.5:1080")
      expect(authed.to_h).to eq(
        "protocol" => "socks5", "address" => "10.0.0.5:1080",
        "credentials" => {
          "username" => "sandbox",
          "password" => {"kind" => "env", "var" => "PROXY_PASSWORD"}
        }
      )
    end

    it "accepts a { env: } Hash as the password source" do
      authed = described_class.socks5("10.0.0.5:1080").credentials("sandbox", {env: "PW"})
      expect(authed.password).to eq(Microsandbox::SecretSource.env("PW"))
    end

    it "rejects a plaintext password (only an env-backed SecretSource exists)" do
      expect { described_class.socks5("10.0.0.5:1080").credentials("sandbox", "hunter2") }
        .to raise_error(ArgumentError, /expects a Microsandbox::SecretSource.*got String/)
    end

    it "is frozen" do
      expect(described_class.socks5("10.0.0.5:1080")).to be_frozen
    end
  end

  describe "validation (mirrors Python OutboundProxy.__post_init__)" do
    it "rejects user_id on SOCKS5" do
      expect { described_class.new(protocol: :socks5, address: "127.0.0.1:1080", user_id: "x") }
        .to raise_error(ArgumentError, /user_id is only supported for SOCKS4/)
    end

    it "rejects credentials on SOCKS4" do
      expect do
        described_class.new(protocol: :socks4, address: "127.0.0.1:1080",
          username: "u", password: env_source)
      end.to raise_error(ArgumentError, /credentials are only supported for SOCKS5/)
    end

    it "requires username and password together" do
      expect { described_class.new(protocol: :socks5, address: "127.0.0.1:1080", username: "u") }
        .to raise_error(ArgumentError, /username and password must be provided together/)
      expect do
        described_class.new(protocol: :socks5, address: "127.0.0.1:1080", password: env_source)
      end.to raise_error(ArgumentError, /username and password must be provided together/)
    end

    it "rejects an unknown protocol" do
      expect { described_class.new(protocol: :http, address: "127.0.0.1:3128") }
        .to raise_error(ArgumentError, /unsupported outbound proxy protocol "http"/)
    end

    it "requires a non-empty String address (IP:port parsing is left to the core)" do
      expect { described_class.socks5("") }
        .to raise_error(ArgumentError, /non-empty "IP:port" String/)
      expect { described_class.socks5(nil) }
        .to raise_error(ArgumentError, /non-empty "IP:port" String/)
      expect { described_class.socks5(1080) }
        .to raise_error(ArgumentError, /non-empty "IP:port" String/)
    end
  end

  describe ".coerce" do
    it "passes an OutboundProxy through as its wire hash" do
      proxy = described_class.socks5("127.0.0.1:1080").credentials("u", env_source)
      expect(described_class.coerce(proxy)).to eq(proxy.to_h)
    end

    it "normalizes a symbol-keyed SOCKS5 Hash with { env: } password" do
      wire = described_class.coerce(
        protocol: :socks5, address: "127.0.0.1:1080",
        credentials: {username: "u", password: {env: "VAR"}}
      )
      expect(wire).to eq(
        "protocol" => "socks5", "address" => "127.0.0.1:1080",
        "credentials" => {"username" => "u", "password" => {"kind" => "env", "var" => "VAR"}}
      )
    end

    it "normalizes a string-keyed SOCKS4 Hash with user_id" do
      wire = described_class.coerce("protocol" => "socks4", "address" => "127.0.0.1:1080", "user_id" => "ci")
      expect(wire).to eq("protocol" => "socks4", "address" => "127.0.0.1:1080", "user_id" => "ci")
    end

    it "accepts the wire-form password { kind: 'env', var: } too" do
      wire = described_class.coerce(
        protocol: "socks5", address: "127.0.0.1:1080",
        credentials: {username: "u", password: {kind: "env", var: "VAR"}}
      )
      expect(wire.dig("credentials", "password")).to eq("kind" => "env", "var" => "VAR")
    end

    it "rejects a Hash missing protocol: or address:" do
      expect { described_class.coerce(address: "127.0.0.1:1080") }
        .to raise_error(ArgumentError, /requires protocol:/)
      expect { described_class.coerce(protocol: :socks5) }
        .to raise_error(ArgumentError, /requires address:/)
    end

    it "rejects half-specified or malformed credentials" do
      expect { described_class.coerce(protocol: :socks5, address: "a:1", credentials: {username: "u"}) }
        .to raise_error(ArgumentError, /requires both username: and password:/)
      expect { described_class.coerce(protocol: :socks5, address: "a:1", credentials: "u:p") }
        .to raise_error(ArgumentError, /credentials: must be a Hash/)
      expect do
        described_class.coerce(protocol: :socks5, address: "a:1",
          credentials: {username: "u", password: {kind: "file", var: "x"}})
      end.to raise_error(ArgumentError, /only environment-backed secret sources/)
      expect do
        described_class.coerce(protocol: :socks5, address: "a:1",
          credentials: {username: "u", password: {path: "/x"}})
      end.to raise_error(ArgumentError, /expects \{ env: "VAR" \}/)
    end

    it "applies the SOCKS4/SOCKS5 rules to Hashes as well" do
      expect { described_class.coerce(protocol: :socks5, address: "a:1", user_id: "x") }
        .to raise_error(ArgumentError, /user_id is only supported for SOCKS4/)
      expect do
        described_class.coerce(protocol: :socks4, address: "a:1",
          credentials: {username: "u", password: {env: "V"}})
      end.to raise_error(ArgumentError, /credentials are only supported for SOCKS5/)
    end

    it "rejects other value types" do
      expect { described_class.coerce("socks5://127.0.0.1:1080") }
        .to raise_error(ArgumentError, /proxy: expects a Microsandbox::OutboundProxy.*got String/)
    end
  end

  describe "#inspect" do
    it "names the password env var but never a value" do
      proxy = described_class.socks5("127.0.0.1:1080").credentials("u", env_source)
      expect(proxy.inspect).to eq(
        "#<Microsandbox::OutboundProxy socks5 127.0.0.1:1080 username=u password=env:PROXY_PASSWORD>"
      )
    end
  end
end

RSpec.describe Microsandbox::SecretSource do
  it ".env builds a frozen env-backed source with the wire hash" do
    src = described_class.env("TOKEN")
    expect(src.kind).to eq("env")
    expect(src.var).to eq("TOKEN")
    expect(src).to be_frozen
    expect(src.to_h).to eq("kind" => "env", "var" => "TOKEN")
    expect(src.inspect).to eq("#<Microsandbox::SecretSource env=TOKEN>")
  end

  it "accepts a Symbol variable name" do
    expect(described_class.env(:TOKEN).var).to eq("TOKEN")
  end

  it "rejects an empty variable name" do
    expect { described_class.env("") }
      .to raise_error(ArgumentError, /must not be empty/)
  end

  it "rejects any kind other than env" do
    expect { described_class.new("file", "/x") }
      .to raise_error(ArgumentError, /only environment-backed secret sources are supported/)
  end

  it "compares by value" do
    expect(described_class.env("A")).to eq(described_class.env("A"))
    expect(described_class.env("A")).not_to eq(described_class.env("B"))
    expect([described_class.env("A"), described_class.env("A")].uniq.size).to eq(1)
  end
end
