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

  # A caller who reaches for `{ value: }` / `{ store: }` / a bare String by
  # analogy with other secret APIs has just handed us a real password. The
  # rejection must describe the expected shape only — the secret must not
  # resurface in the exception (which ends up in logs and bug reports).
  describe "rejected password values never leak into error messages" do
    let(:secret) { "SYNTHETIC-SECRET-b7c1e0-do-not-log" }
    let(:base) { described_class.socks5("10.0.0.5:1080") }

    shared_examples "a redacted rejection" do |label|
      it "for #{label}" do
        expect { base.credentials("u", bad_password) }.to raise_error(ArgumentError) { |e|
          expect(e.message).not_to include(secret)
          expect(e.message).not_to include("SYNTHETIC")
        }
      end

      it "for #{label} via the Hash form of proxy:" do
        expect do
          described_class.coerce(protocol: :socks5, address: "10.0.0.5:1080",
            credentials: {username: "u", password: bad_password})
        end.to raise_error(ArgumentError) { |e|
          expect(e.message).not_to include(secret)
          expect(e.message).not_to include("SYNTHETIC")
        }
      end
    end

    context "with { value: } (plaintext by analogy with secrets:)" do
      let(:bad_password) { {value: secret} }
      include_examples "a redacted rejection", "{ value: }"
    end

    context "with { store: } (an unsupported source kind)" do
      let(:bad_password) { {store: secret} }
      include_examples "a redacted rejection", "{ store: }"
    end

    context "with a plain String" do
      let(:bad_password) { secret }
      include_examples "a redacted rejection", "a plain String"
    end

    context "with a malformed nested Hash inside env:" do
      let(:bad_password) { {env: {value: secret}} }
      include_examples "a redacted rejection", "{ env: { value: } }"
    end

    context "with a malformed nested Hash inside kind:/var:" do
      let(:bad_password) { {kind: {value: secret}, var: {value: secret}} }
      include_examples "a redacted rejection", "{ kind: {...}, var: {...} }"
    end

    # An unsupported kind that is itself a String/Symbol (a password mis-keyed
    # into kind:) must be reported by class only — with a valid var and with a
    # malformed one, through both entry points.
    [
      ["a String kind, valid var", {kind: "SYNTHETIC-SECRET-b7c1e0-do-not-log", var: "PW"}],
      ["a Symbol kind, valid var", {kind: :"SYNTHETIC-SECRET-b7c1e0-do-not-log", var: "PW"}],
      ["a String kind, malformed var", {kind: "SYNTHETIC-SECRET-b7c1e0-do-not-log", var: {value: "x"}}],
      ["a Symbol kind, malformed var", {kind: :"SYNTHETIC-SECRET-b7c1e0-do-not-log", var: {value: "SYNTHETIC-SECRET-b7c1e0-do-not-log"}}]
    ].each do |label, bad|
      context "with #{label}" do
        let(:bad_password) { bad }
        include_examples "a redacted rejection", label

        it "names only the allowed kind and the input class" do
          expect { base.credentials("u", bad_password) }
            .to raise_error(ArgumentError, /secret source kind must be "env".*got an unsupported (String|Symbol)\)/)
        end
      end
    end

    it "does not render a non-String address or protocol either" do
      expect { described_class.new(protocol: {value: secret}, address: "a:1") }
        .to raise_error(ArgumentError) { |e| expect(e.message).not_to include(secret) }
      expect { described_class.new(protocol: :socks5, address: {value: secret}) }
        .to raise_error(ArgumentError) { |e| expect(e.message).not_to include(secret) }
    end

    it "does not render an unsupported String/Symbol protocol value" do
      expect { described_class.new(protocol: secret, address: "a:1") }
        .to raise_error(ArgumentError, /unsupported outbound proxy protocol \(expected/) { |e|
          expect(e.message).not_to include(secret)
        }
      expect { described_class.coerce(protocol: secret.to_sym, address: "a:1") }
        .to raise_error(ArgumentError) { |e| expect(e.message).not_to include(secret) }
    end
  end

  # user_id / username are documented Strings. A misplaced container — say a
  # credentials Hash handed to `username:` — must be rejected by class, not
  # stringified into the wire hash or #inspect (where its contents would show).
  describe "non-String identifiers are rejected without rendering them" do
    let(:secret) { "SYNTHETIC-SECRET-b7c1e0-do-not-log" }
    let(:env_pw) { Microsandbox::SecretSource.env("PW") }

    shared_examples "a rejected identifier" do |label|
      it "via the factory / #credentials (#{label})" do
        expect(&factory).to raise_error(ArgumentError, /must be a String \(got (Hash|Array)\)/) { |e|
          expect(e.message).not_to include(secret)
          expect(e.message).not_to include("SYNTHETIC")
        }
      end

      it "via the Hash form of proxy: (#{label})" do
        expect(&hash_form).to raise_error(ArgumentError, /must be a String \(got (Hash|Array)\)/) { |e|
          expect(e.message).not_to include(secret)
          expect(e.message).not_to include("SYNTHETIC")
        }
      end
    end

    context "SOCKS5 username as a Hash" do
      let(:factory) { -> { described_class.socks5("a:1").credentials({password: secret}, env_pw) } }
      let(:hash_form) do
        -> {
          described_class.coerce(protocol: :socks5, address: "a:1",
            credentials: {username: {password: secret}, password: {env: "PW"}})
        }
      end
      include_examples "a rejected identifier", "Hash username"
    end

    context "SOCKS5 username as an Array" do
      let(:factory) { -> { described_class.socks5("a:1").credentials([secret], env_pw) } }
      let(:hash_form) do
        -> {
          described_class.coerce(protocol: :socks5, address: "a:1",
            credentials: {username: [secret], password: {env: "PW"}})
        }
      end
      include_examples "a rejected identifier", "Array username"
    end

    context "SOCKS4 user_id as a Hash" do
      let(:factory) { -> { described_class.socks4("a:1", user_id: {password: secret}) } }
      let(:hash_form) { -> { described_class.coerce(protocol: :socks4, address: "a:1", user_id: {password: secret}) } }
      include_examples "a rejected identifier", "Hash user_id"
    end

    context "SOCKS4 user_id as an Array" do
      let(:factory) { -> { described_class.socks4("a:1", user_id: [secret]) } }
      let(:hash_form) { -> { described_class.coerce(protocol: :socks4, address: "a:1", user_id: [secret]) } }
      include_examples "a rejected identifier", "Array user_id"
    end

    it "still accepts Symbol identifiers, normalized to frozen Strings" do
      expect(described_class.socks4("a:1", user_id: :ci).to_h["user_id"]).to eq("ci")
      authed = described_class.socks5("a:1").credentials(:sandbox, env_pw)
      expect(authed.username).to eq("sandbox")
      expect(authed.username).to be_frozen
    end

    # Belt and braces for the rendering surfaces themselves: nothing that gets
    # constructed can carry the sentinel, so neither #inspect nor #to_h can.
    it "keeps the sentinel out of #inspect and #to_h of every object that CAN be built" do
      built = [
        described_class.socks4("a:1", user_id: "ci"),
        described_class.socks5("a:1").credentials("u", Microsandbox::SecretSource.env("PW"))
      ]
      built.each do |p|
        expect(p.inspect).not_to include("SYNTHETIC")
        expect(p.to_h.inspect).not_to include("SYNTHETIC")
      end
    end
  end

  # "Immutable" has to mean more than the outer object's frozen bit: the value
  # object must not alias the caller's Strings (which the caller may go on to
  # reuse and mutate), and Strings handed out by readers / #to_h must not be a
  # back door into stored state.
  describe "deep immutability" do
    let(:addr) { +"127.0.0.1:1080" }
    let(:var) { +"ORIGINAL_PASSWORD_VAR" }
    let(:user) { +"original-user" }
    let(:uid) { +"original-uid" }
    let(:proto) { +"socks5" }
    let(:source) { Microsandbox::SecretSource.env(var) }
    let(:proxy) { described_class.new(protocol: proto, address: addr).credentials(user, source) }

    it "does not freeze the caller's own Strings" do
      proxy
      expect([addr, var, user, proto]).to all(satisfy { |s| !s.frozen? })
    end

    it "is unaffected by the caller mutating its input Strings after construction" do
      before = proxy.to_h
      addr.replace("192.0.2.50:9999")
      var.replace("OTHER_PASSWORD_VAR")
      user.replace("other-user")
      proto.replace("socks4")
      expect(proxy.to_h).to eq(before)
      expect(described_class.coerce(proxy)).to eq(
        "protocol" => "socks5", "address" => "127.0.0.1:1080",
        "credentials" => {"username" => "original-user",
                          "password" => {"kind" => "env", "var" => "ORIGINAL_PASSWORD_VAR"}}
      )
      expect(source.var).to eq("ORIGINAL_PASSWORD_VAR")
    end

    it "keeps SOCKS4 user_id and SecretSource var private copies too" do
      socks4 = described_class.socks4(addr, user_id: uid)
      uid.replace("other-uid")
      addr.replace("192.0.2.50:9999")
      expect(socks4.to_h).to eq("protocol" => "socks4", "address" => "127.0.0.1:1080", "user_id" => "original-uid")
    end

    it "hands out frozen Strings from every reader" do
      expect(proxy.protocol).to be_frozen
      expect(proxy.address).to be_frozen
      expect(proxy.username).to be_frozen
      expect(proxy.password.var).to be_frozen
      expect(proxy.password.kind).to be_frozen
      expect(described_class.socks4("a:1", user_id: "x").user_id).to be_frozen
      expect { proxy.protocol.replace("socks4") }.to raise_error(FrozenError)
      expect { proxy.address << ":evil" }.to raise_error(FrozenError)
      expect { proxy.password.var.replace("OTHER") }.to raise_error(FrozenError)
    end

    it "hands out frozen Strings through #to_h, so the wire hash cannot mutate stored state" do
      wire = proxy.to_h
      expect { wire["protocol"].replace("socks4") }.to raise_error(FrozenError)
      expect { wire["address"] << ":evil" }.to raise_error(FrozenError)
      expect { wire["credentials"]["username"].replace("x") }.to raise_error(FrozenError)
      expect { wire["credentials"]["password"]["var"].replace("VIA_RETURNED_HASH") }
        .to raise_error(FrozenError)
      # The Hash containers themselves are fresh per call — replacing a slot
      # in one does not reach the object.
      wire["protocol"] = "socks4"
      expect(proxy.protocol).to eq("socks5")
      expect(proxy.to_h["protocol"]).to eq("socks5")
    end

    it "keeps value-based equality and hash stable after the caller mutates inputs" do
      other = described_class.socks5("127.0.0.1:1080")
        .credentials("original-user", Microsandbox::SecretSource.env("ORIGINAL_PASSWORD_VAR"))
      set = {proxy => true}
      addr.replace("192.0.2.50:9999")
      user.replace("other-user")
      expect(proxy).to eq(other)
      expect(proxy.hash).to eq(other.hash)
      expect(set[other]).to be(true)
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

    it "rejects an unknown protocol (without echoing the value)" do
      expect { described_class.new(protocol: :http, address: "127.0.0.1:3128") }
        .to raise_error(ArgumentError, /unsupported outbound proxy protocol \(expected :socks4 or :socks5\)/)
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

  it "rejects a non-String variable name by class, without rendering it" do
    expect { described_class.env({value: "SYNTHETIC-SECRET"}) }
      .to raise_error(ArgumentError) { |e|
        expect(e.message).to match(/must be a String name \(got Hash\)/)
        expect(e.message).not_to include("SYNTHETIC")
      }
  end

  it "does not alias or freeze the caller's variable-name String" do
    name = +"TOKEN"
    src = described_class.env(name)
    name.replace("OTHER")
    expect(name).not_to be_frozen
    expect(src.var).to eq("TOKEN")
    expect(src.var).to be_frozen
    expect { src.to_h["var"] << "X" }.to raise_error(FrozenError)
  end

  it "compares by value" do
    expect(described_class.env("A")).to eq(described_class.env("A"))
    expect(described_class.env("A")).not_to eq(described_class.env("B"))
    expect([described_class.env("A"), described_class.env("A")].uniq.size).to eq(1)
  end
end
