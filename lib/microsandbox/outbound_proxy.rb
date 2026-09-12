# frozen_string_literal: true

module Microsandbox
  # Host-side source for secret material (runtime v0.6.17). The only kind is
  # `env`: the secret is read from an environment variable of the **host**
  # process (the one running this gem) when the sandbox is created — the
  # variable's *name* travels to the runtime, never its value.
  #
  # Used for the password of an authenticated SOCKS5 {OutboundProxy}. Mirrors
  # the Python SDK's frozen `SecretSource` dataclass.
  #
  # @example
  #   Microsandbox::SecretSource.env("PROXY_PASSWORD")
  class SecretSource
    KINDS = %w[env].freeze

    # @return [String] the source kind (always `"env"`)
    attr_reader :kind
    # @return [String] the host environment variable name
    attr_reader :var

    # Resolve the secret from a host environment variable.
    # @param variable [String, Symbol] the variable name (non-empty)
    # @return [SecretSource]
    def self.env(variable)
      new("env", variable)
    end

    # Coerce a user-facing value into a {SecretSource}: an instance passes
    # through, a Hash must be `{ env: "VAR" }` or the wire form
    # `{ kind: "env", var: "VAR" }`.
    # @api private
    def self.coerce(value, context = "password")
      case value
      when SecretSource then value
      when Hash
        env = fetch_key(value, :env)
        return new("env", env) unless env.nil?

        kind = fetch_key(value, :kind)
        var = fetch_key(value, :var)
        if kind.nil? && var.nil?
          raise ArgumentError, "#{context}: expects { env: \"VAR\" } (got #{value.inspect})"
        end
        new(kind, var)
      else
        raise ArgumentError,
          "#{context}: expects a Microsandbox::SecretSource (SecretSource.env(\"VAR\")) " \
          "or a Hash { env: \"VAR\" } (got #{value.class})"
      end
    end

    # @api private
    def self.fetch_key(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
    private_class_method :fetch_key

    # @api private — use {.env}.
    def initialize(kind, var)
      kind = kind.to_s
      unless KINDS.include?(kind)
        raise ArgumentError,
          "only environment-backed secret sources are supported (got kind #{kind.inspect})"
      end
      var = var.to_s
      raise ArgumentError, "secret source environment variable must not be empty" if var.empty?
      @kind = kind
      @var = var
      freeze
    end

    # Wire form for the native layer (Python's `_to_dict`).
    # @return [Hash{String => String}]
    def to_h
      {"kind" => @kind, "var" => @var}
    end

    def ==(other)
      other.is_a?(SecretSource) && other.kind == kind && other.var == var
    end
    alias_method :eql?, :==

    def hash
      [SecretSource, @kind, @var].hash
    end

    def inspect
      "#<Microsandbox::SecretSource env=#{@var}>"
    end
  end

  # An outbound proxy for a sandbox's egress traffic (runtime v0.6.17, upstream
  # #1234 / #1507), passed to {Sandbox.create} via `proxy:`. The runtime's
  # host-side network stack dials the proxy — so the address is resolved from
  # the **host**, and `127.0.0.1` names the host's loopback, not the guest's.
  #
  # - {socks4} — SOCKS4 for TCP, with an optional `user_id:` sent in the
  #   handshake.
  # - {socks5} — SOCKS5 for TCP and non-DNS UDP; chain {#credentials} for
  #   username/password authentication, the password coming from a host
  #   {SecretSource} (only its variable name reaches the runtime).
  #
  # The proxy applies uniformly to TLS-intercepted and bypassed/plain TCP; the
  # egress policy (`network:`) still decides which destinations may be reached.
  # Not accepted by the cloud backend (`UnsupportedError`).
  #
  # Instances are immutable: {#credentials} returns a new proxy. `proxy:` also
  # accepts the equivalent plain Hash (see {.coerce}).
  #
  # @example
  #   Sandbox.create("worker", image: "python",
  #     proxy: Microsandbox::OutboundProxy.socks5("127.0.0.1:1080"))
  #   Sandbox.create("worker", image: "python",
  #     proxy: Microsandbox::OutboundProxy.socks5("10.0.0.5:1080")
  #       .credentials("sandbox", Microsandbox::SecretSource.env("PROXY_PASSWORD")))
  #   Sandbox.create("worker", image: "python",
  #     proxy: { protocol: :socks4, address: "127.0.0.1:1080", user_id: "ci" })
  #
  # Mirrors the Python SDK's frozen `OutboundProxy` dataclass (`socks4` /
  # `socks5` / `credentials`).
  class OutboundProxy
    PROTOCOLS = %w[socks4 socks5].freeze

    # @return [String] `"socks4"` or `"socks5"`
    attr_reader :protocol
    # @return [String] the proxy's `IP:port` address, as seen from the host
    attr_reader :address
    # @return [String, nil] SOCKS4 user ID
    attr_reader :user_id
    # @return [String, nil] SOCKS5 username
    attr_reader :username
    # @return [SecretSource, nil] SOCKS5 password source
    attr_reader :password

    # A SOCKS4 outbound proxy.
    # @param address [String] `IP:port` of the proxy, resolved from the host
    # @param user_id [String, nil] optional user ID sent in the SOCKS4 handshake
    # @return [OutboundProxy]
    def self.socks4(address, user_id: nil)
      new(protocol: "socks4", address: address, user_id: user_id)
    end

    # A SOCKS5 outbound proxy (unauthenticated; chain {#credentials}).
    # @param address [String] `IP:port` of the proxy, resolved from the host
    # @return [OutboundProxy]
    def self.socks5(address)
      new(protocol: "socks5", address: address)
    end

    # Coerce a user-facing `proxy:` value into the normalized wire Hash:
    # an {OutboundProxy}, or a Hash `{ protocol: :socks4|:socks5, address:,
    # user_id:, credentials: { username:, password: SecretSource | { env: } } }`.
    # @api private
    # @return [Hash{String => untyped}]
    def self.coerce(value)
      case value
      when OutboundProxy then value.to_h
      when Hash then from_hash(value).to_h
      else
        raise ArgumentError,
          "proxy: expects a Microsandbox::OutboundProxy (OutboundProxy.socks4/socks5) " \
          "or a Hash { protocol:, address:, ... } (got #{value.class})"
      end
    end

    # @api private
    def self.from_hash(hash)
      protocol = fetch_key(hash, :protocol)
      raise ArgumentError, "proxy: requires protocol: (:socks4 or :socks5)" if protocol.nil?
      address = fetch_key(hash, :address)
      raise ArgumentError, "proxy: requires address:" if address.nil?
      user_id = fetch_key(hash, :user_id)
      credentials = fetch_key(hash, :credentials)
      username = nil
      password = nil
      unless credentials.nil?
        unless credentials.is_a?(Hash)
          raise ArgumentError,
            "proxy credentials: must be a Hash { username:, password: } (got #{credentials.class})"
        end
        username = fetch_key(credentials, :username)
        password = fetch_key(credentials, :password)
        if username.nil? || password.nil?
          raise ArgumentError, "proxy credentials: requires both username: and password:"
        end
        password = SecretSource.coerce(password, "proxy credentials password")
      end
      new(protocol: protocol, address: address, user_id: user_id,
        username: username, password: password)
    end

    # @api private
    def self.fetch_key(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
    private_class_method :fetch_key

    # @api private — use {.socks4} / {.socks5}.
    def initialize(protocol:, address:, user_id: nil, username: nil, password: nil)
      protocol = protocol.to_s.downcase
      unless PROTOCOLS.include?(protocol)
        raise ArgumentError,
          "unsupported outbound proxy protocol #{protocol.inspect} (expected :socks4 or :socks5)"
      end
      unless address.is_a?(String) && !address.empty?
        raise ArgumentError,
          "proxy address must be a non-empty \"IP:port\" String (got #{address.inspect})"
      end
      # Same rules as the Python SDK's OutboundProxy.__post_init__; the address
      # itself is parsed by the core (which reports e.g. "invalid SOCKS5 proxy
      # address" as an InvalidConfigError at create time).
      if protocol != "socks4" && !user_id.nil?
        raise ArgumentError, "user_id is only supported for SOCKS4 proxies"
      end
      if protocol != "socks5" && !(username.nil? && password.nil?)
        raise ArgumentError, "credentials are only supported for SOCKS5 proxies"
      end
      if username.nil? != password.nil?
        raise ArgumentError, "SOCKS5 username and password must be provided together"
      end
      unless password.nil? || password.is_a?(SecretSource)
        raise ArgumentError,
          "SOCKS5 password must be a Microsandbox::SecretSource (SecretSource.env(\"VAR\")), " \
          "got #{password.class}"
      end
      @protocol = protocol
      @address = address
      @user_id = user_id&.to_s
      @username = username&.to_s
      @password = password
      freeze
    end

    # Username/password authentication for a SOCKS5 proxy. Returns a **new**
    # proxy; the receiver is unchanged.
    # @param username [String]
    # @param password [SecretSource] host-side password source
    #   ({SecretSource.env}); its variable *name* is what reaches the runtime
    # @return [OutboundProxy]
    # @raise [ArgumentError] on a SOCKS4 proxy
    def credentials(username, password)
      raise ArgumentError, "credentials are only supported for SOCKS5 proxies" unless socks5?
      self.class.new(protocol: @protocol, address: @address,
        username: username, password: SecretSource.coerce(password, "proxy credentials password"))
    end

    def socks4? = @protocol == "socks4"

    def socks5? = @protocol == "socks5"

    # Wire form for the native layer (Python's `_to_dict`): `user_id` only when
    # set, `credentials` only when both halves are set.
    # @return [Hash{String => untyped}]
    def to_h
      h = {"protocol" => @protocol, "address" => @address}
      h["user_id"] = @user_id unless @user_id.nil?
      if @username && @password
        h["credentials"] = {"username" => @username, "password" => @password.to_h}
      end
      h
    end

    def ==(other)
      other.is_a?(OutboundProxy) && other.to_h == to_h
    end
    alias_method :eql?, :==

    def hash
      [OutboundProxy, to_h].hash
    end

    # Never renders a password value — there is none; only the env var name.
    def inspect
      parts = ["#{@protocol} #{@address}"]
      parts << "user_id=#{@user_id}" if @user_id
      parts << "username=#{@username} password=env:#{@password.var}" if @username
      "#<Microsandbox::OutboundProxy #{parts.join(" ")}>"
    end
  end
end
