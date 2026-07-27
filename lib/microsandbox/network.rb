# frozen_string_literal: true

module Microsandbox
  # Factory for network-policy **rule destinations**. A destination is what an
  # egress rule reaches (or, for an ingress rule, the connecting peer). Use the
  # explicit constructors for unambiguous typing, or pass a plain String to
  # {Rule.allow}/{Rule.deny} for shorthand classification (see {Rule}).
  #
  # @example
  #   Microsandbox::Destination.cidr("10.0.0.0/8")
  #   Microsandbox::Destination.domain("api.openai.com")
  #   Microsandbox::Destination.group(:public)
  #
  # Mirrors the `Destination` factory in the official Python/Node/Go SDKs.
  module Destination
    module_function

    # Match any destination.
    def any = {"destination_kind" => "any"}

    # A single IP address (stored as a /32 or /128).
    def ip(value) = {"destination_kind" => "ip", "destination" => value.to_s}

    # An IP network in CIDR notation (e.g. "10.0.0.0/8").
    def cidr(value) = {"destination_kind" => "cidr", "destination" => value.to_s}

    # An exact domain name (matched against the resolved-hostname cache / SNI).
    def domain(value) = {"destination_kind" => "domain", "destination" => value.to_s}

    # A domain suffix — matches the apex and any subdomain (e.g. ".internal").
    def domain_suffix(value) = {"destination_kind" => "domain_suffix", "destination" => value.to_s}

    # A predefined group: :public, :loopback, :private, :link_local, :metadata,
    # :multicast, or :host.
    def group(value) = {"destination_kind" => "group", "destination" => value.to_s.tr("_", "-")}
  end

  # Factory for a single network-policy **rule**. A rule pairs an action
  # (allow/deny) with a direction, a destination, and optional protocol/port
  # filters; rules are evaluated first-match-wins per direction.
  #
  # @example
  #   Microsandbox::Rule.allow(destination: "1.1.1.1", protocol: :tcp, port: "443")
  #   Microsandbox::Rule.deny(destination: Microsandbox::Destination.group(:metadata))
  #   Microsandbox::Rule.allow(direction: :ingress, destination: "10.0.0.0/8", port: "8000-9000")
  #
  # `destination:` accepts a {Destination} Hash, a shorthand String
  # ("*", "public", "1.1.1.1", "10.0.0.0/8", ".internal", "api.example.com"),
  # or nil (any). Mirrors the `Rule` factory in the official SDKs.
  module Rule
    module_function

    # Build an allow rule. See {Rule} for argument semantics.
    # @return [Hash]
    def allow(destination: nil, direction: :egress, protocol: nil, protocols: nil, port: nil, ports: nil)
      build("allow", destination, direction, protocol, protocols, port, ports)
    end

    # Build a deny rule.
    # @return [Hash]
    def deny(destination: nil, direction: :egress, protocol: nil, protocols: nil, port: nil, ports: nil)
      build("deny", destination, direction, protocol, protocols, port, ports)
    end

    # Allow plain DNS (UDP/53 and TCP/53) to the sandbox gateway — the rule
    # the composable profiles prepend automatically. Use it in custom policies
    # that need name resolution. Expands to the same rule as the core's
    # `Rule::allow_dns` (egress → group :host, udp+tcp, port 53).
    # @return [Hash]
    def allow_dns
      {"action" => "allow", "direction" => "egress",
       "destination_kind" => "group", "destination" => "host",
       "protocols" => %w[udp tcp], "ports" => ["53"]}
    end

    # Deny plain DNS to the sandbox gateway — the deny counterpart of
    # {allow_dns}, useful as an override placed before profile-generated rules.
    # @return [Hash]
    def deny_dns
      allow_dns.merge("action" => "deny")
    end

    # @api private
    def build(action, destination, direction, protocol, protocols, port, ports)
      rule = {"action" => action, "direction" => direction.to_s}
      rule.merge!(normalize_destination(destination))
      protos = (Array(protocols) + Array(protocol)).compact.map(&:to_s)
      rule["protocols"] = protos unless protos.empty?
      prts = (Array(ports) + Array(port)).compact.map(&:to_s)
      rule["ports"] = prts unless prts.empty?
      rule
    end

    # @api private
    def normalize_destination(dest)
      case dest
      when nil then {}
      when Hash then dest.each_with_object({}) { |(k, v), a| a[k.to_s] = v }
      when String, Symbol then {"destination" => dest.to_s}
      else raise ArgumentError, "invalid rule destination: #{dest.inspect}"
      end
    end
  end

  # A sandbox network policy: composed profiles, a terminal preset, or a custom
  # set of allow/deny {Rule}s with per-direction default actions and bulk
  # domain denials.
  #
  # Pass to {Sandbox.create} via `network:` — a {NetworkPolicy}, an Array of
  # profile names (`[:public, :host]`), a single profile or preset name
  # (String/Symbol), or a plain Hash with the same keys as {custom}.
  #
  # Profiles (runtime v0.6.7) compose: `:public` (public internet), `:private`
  # (LAN/private ranges), `:host` (the host machine/gateway). Any non-empty
  # combination automatically allows gateway DNS. The default policy — public
  # internet only — equals `from_profiles(:public)`.
  #
  # @example profiles
  #   Sandbox.create("b", image: "alpine", network: [:public, :private])
  #   Sandbox.create("b", image: "alpine", network: :none)
  #   Sandbox.create("b", image: "alpine", network: NetworkPolicy.from_profiles(:host))
  #
  # @example custom
  #   policy = Microsandbox::NetworkPolicy.custom(
  #     default_egress: :deny,
  #     rules: [
  #       Microsandbox::Rule.allow_dns,
  #       Microsandbox::Rule.allow(destination: "api.openai.com", protocol: :tcp, port: "443"),
  #     ],
  #     deny_domain_suffixes: [".ads.example"],
  #   )
  #   Sandbox.create("b", image: "alpine", network: policy)
  #
  # Mirrors `NetworkPolicy` / `Network` in the official Python/Node/Go SDKs.
  class NetworkPolicy
    # Composable profile names (runtime v0.6.7).
    PROFILES = %w[public private host].freeze

    # Canonical preset names keyed by every accepted alias. Only the terminal
    # presets survive v0.6.7; the removed ones get migration guidance in
    # {canonical_preset}.
    PRESET_ALIASES = {
      "none" => "none", "disabled" => "none", "disable" => "none", "airgapped" => "none",
      "all" => "allow_all", "allow_all" => "allow_all", "allow-all" => "allow_all"
    }.freeze

    # Removed v0.6.6 preset spellings → the exact profile replacement, used to
    # build actionable migration errors. (`public_only` expanded to precisely
    # `from_profiles(:public)`, `non_local` to `from_profiles(:public, :private)` —
    # the replacements are rule-for-rule equivalent.)
    REMOVED_PRESETS = {
      "public_only" => "network: [:public] (or NetworkPolicy.from_profiles(:public); " \
        "this is still the default policy)",
      "public-only" => "network: [:public]",
      "non_local" => "network: [:public, :private] " \
        "(or NetworkPolicy.from_profiles(:public, :private))",
      "non-local" => "network: [:public, :private]",
      "nonlocal" => "network: [:public, :private]"
    }.freeze

    class << self
      # Compose a policy from network profiles (`:public`, `:private`, `:host`).
      # Order and duplicates don't matter — the runtime expands the set into a
      # canonical rule list plus a gateway-DNS allow. An empty set is a valid
      # deny-egress/allow-ingress policy with no rules (and no DNS).
      # @return [NetworkPolicy]
      def from_profiles(*profiles)
        list = normalize_profiles(profiles)
        if list.empty?
          # Same semantics as the runtime's from_profiles([]) — expressed as an
          # explicit empty custom policy so the wire needs no empty-array case.
          custom(default_egress: :deny, default_ingress: :allow, rules: [])
        else
          new("profiles" => list)
        end
      end

      # @return [NetworkPolicy] block all network access
      def none = preset("none")

      # @return [NetworkPolicy] permit all traffic
      def allow_all = preset("allow_all")

      # @return [NetworkPolicy] a bare preset policy (:none or :allow_all)
      def preset(name)
        new("preset" => canonical_preset(name))
      end

      # Build a custom policy — an ordered rule list with per-direction default
      # actions. A custom policy stands on its own; to start from a profile
      # base, use the Hash form passed to {Sandbox.create} (`profiles:` composes
      # with `rules:`/deny lists). A terminal `preset:` stays exclusive with
      # custom rules/defaults, mirroring the official SDKs. Custom policies
      # need an explicit {Rule.allow_dns} if the sandbox should resolve names.
      #
      # @param default_egress [:deny, :allow, nil] fall-through for unmatched
      #   outbound traffic (default :deny)
      # @param default_ingress [:deny, :allow, nil] fall-through for unmatched
      #   inbound traffic (default :allow)
      # @param rules [Array<Hash>] ordered {Rule}s (first match wins per direction)
      # @param deny_domains [Array<String>] exact domains to deny egress to
      #   (prepended, so they outrank later allow rules)
      # @param deny_domain_suffixes [Array<String>] domain suffixes to deny
      # @return [NetworkPolicy]
      def custom(default_egress: :deny, default_ingress: :allow, rules: [],
        deny_domains: [], deny_domain_suffixes: [])
        h = {}
        h["default_egress"] = action_str(default_egress) unless default_egress.nil?
        h["default_ingress"] = action_str(default_ingress) unless default_ingress.nil?
        h["rules"] = Array(rules).map { |r| normalize_rule(r) }
        add_deny_lists(h, deny_domains, deny_domain_suffixes)
        new(h)
      end

      # Coerce a user-facing `network:` value into a normalized wire Hash.
      # @api private
      def coerce(network)
        case network
        when NetworkPolicy then network.to_h
        when Array then from_profiles(*network).to_h
        when String, Symbol then coerce_name(network)
        when Hash then from_hash(network)
        else
          raise ArgumentError,
            "network: expects profile(s) (:public/:private/:host, or an Array of them), " \
            "a preset (:none/:allow_all), a Microsandbox::NetworkPolicy, or a Hash " \
            "(got #{network.class})"
        end
      end

      private

      # A bare String/Symbol names a single profile (`:public`/`:private`/
      # `:host`) or a terminal preset (`:none`/`:allow_all` and aliases).
      # `"default"` stays accepted and means the default policy, which is
      # exactly the `:public` profile.
      def coerce_name(name)
        key = name.to_s.downcase
        return {"profiles" => [key]} if PROFILES.include?(key)
        return {"profiles" => ["public"]} if key == "default"

        {"preset" => canonical_preset(key)}
      end

      # Validate + stringify a profile list. Removed-preset spellings get the
      # same migration guidance here as in {canonical_preset}, since
      # `network: [:non_local]` is a plausible mis-migration.
      def normalize_profiles(profiles)
        Array(profiles).flatten.map do |p|
          key = p.to_s.downcase
          next key if PROFILES.include?(key)

          if (replacement = REMOVED_PRESETS[key])
            raise ArgumentError,
              "#{p.inspect} is a removed v0.6.6 network preset, not a profile; use #{replacement}"
          end
          raise ArgumentError,
            "unknown network profile #{p.inspect} (expected :public/:private/:host)"
        end
      end

      # A `network:` Hash is composed profiles (`profiles:` + optional rules/
      # defaults/deny lists), a terminal preset (`preset:` + optional deny
      # lists), or a custom policy (`default_egress:`/`default_ingress:`/
      # `rules:` + optional deny lists). Profiles compose with everything —
      # they expand to an ordinary rule base that explicit rules append to —
      # but a preset stays exclusive with rules/defaults: it already defines
      # its rules and defaults, so layering more on top would silently override
      # them. A bare preset or bare profile list is routed to its dedicated
      # wire key by {Sandbox.create}, so the runtime's own expansion applies.
      def from_hash(hash)
        sym = hash.transform_keys(&:to_sym)
        profiles = sym.key?(:profiles) ? normalize_profiles(sym[:profiles]) : nil
        if profiles && sym.key?(:preset)
          raise ArgumentError, "network profiles: and preset: are mutually exclusive"
        end

        if sym.key?(:preset)
          if sym.key?(:rules) || sym.key?(:default_egress) || sym.key?(:default_ingress)
            raise ArgumentError,
              "network preset: cannot be combined with rules:/default_egress:/" \
              "default_ingress: (the preset already defines its rules and defaults); " \
              "only deny_domains:/deny_domain_suffixes: may be layered on a preset"
          end
          h = {"preset" => canonical_preset(sym[:preset])}
          add_deny_lists(h, sym[:deny_domains], sym[:deny_domain_suffixes])
          h
        elsif profiles
          h = {}
          h["profiles"] = profiles unless profiles.empty?
          h["default_egress"] = action_str(sym[:default_egress]) if sym[:default_egress]
          h["default_ingress"] = action_str(sym[:default_ingress]) if sym[:default_ingress]
          rules = Array(sym[:rules]).map { |r| normalize_rule(r) }
          h["rules"] = rules unless rules.empty?
          add_deny_lists(h, sym[:deny_domains], sym[:deny_domain_suffixes])
          # `profiles: []` alone is the runtime's empty composed policy:
          # deny-egress/allow-ingress with no rules (and no DNS).
          h = {"default_egress" => "deny", "default_ingress" => "allow", "rules" => []} if h.empty?
          h
        elsif sym.key?(:rules) || sym.key?(:default_egress) || sym.key?(:default_ingress)
          # An explicit custom policy: the caller chose the rule list and/or the
          # fall-through defaults (which default to :deny / :allow).
          custom(
            default_egress: sym.fetch(:default_egress, :deny),
            default_ingress: sym.fetch(:default_ingress, :allow),
            rules: sym[:rules] || [],
            deny_domains: sym[:deny_domains] || [],
            deny_domain_suffixes: sym[:deny_domain_suffixes] || []
          ).to_h
        else
          # Deny-list-only shorthand (`network: { deny_domains: [...] }`): keep the
          # rest of the network reachable and just block the listed domains, using
          # permissive defaults — mirrors the official SDKs' "full network minus
          # blocked domains" semantics. An empty Hash is a no-op (leaves the
          # default policy in place).
          dd = Array(sym[:deny_domains]).map(&:to_s)
          ds = Array(sym[:deny_domain_suffixes]).map(&:to_s)
          return {} if dd.empty? && ds.empty?

          h = {"default_egress" => "allow", "default_ingress" => "allow"}
          add_deny_lists(h, dd, ds)
          h
        end
      end

      # Append `deny_domains`/`deny_domain_suffixes` to a wire Hash, omitting
      # empty lists. Returns the Hash.
      def add_deny_lists(h, deny_domains, deny_domain_suffixes)
        dd = Array(deny_domains).map(&:to_s)
        h["deny_domains"] = dd unless dd.empty?
        ds = Array(deny_domain_suffixes).map(&:to_s)
        h["deny_domain_suffixes"] = ds unless ds.empty?
        h
      end

      def canonical_preset(name)
        key = name.to_s.downcase
        if (replacement = REMOVED_PRESETS[key])
          raise ArgumentError,
            "the #{name.inspect} network preset was removed in runtime v0.6.7; use #{replacement}"
        end
        PRESET_ALIASES[key] ||
          raise(ArgumentError,
            "unknown network preset #{name.inspect} " \
            "(expected none/allow_all, or profiles :public/:private/:host)")
      end

      def action_str(action)
        case action.to_s.downcase
        when "allow" then "allow"
        when "deny" then "deny"
        else raise ArgumentError, "network action must be :allow or :deny (got #{action.inspect})"
        end
      end

      # Canonicalize a rule Hash (from the {Rule} factory or hand-written) into
      # the wire shape the native parser reads. Accepts singular `protocol`/`port`
      # (the spelling the Go/Python `PolicyRule` use) as well as the plural
      # `protocols`/`ports`, and a `destination` that is a shorthand String or a
      # {Destination} Hash — so a hand-written `{ action:, destination:, protocol:,
      # port: }` rule behaves identically to a factory-built one (without this, a
      # singular `protocol`/`port` was silently dropped, widening the rule).
      def normalize_rule(rule)
        unless rule.is_a?(Hash)
          raise ArgumentError, "rule must be a Hash (use Microsandbox::Rule.allow/deny): #{rule.inspect}"
        end
        sym = rule.transform_keys { |k| k.to_s.to_sym }
        out = {}
        out["action"] = sym[:action].to_s if sym[:action]
        out["direction"] = sym[:direction].to_s if sym[:direction]
        normalize_rule_destination(sym, out)
        protos = (Array(sym[:protocols]) + Array(sym[:protocol])).compact.map(&:to_s)
        out["protocols"] = protos unless protos.empty?
        ports = (Array(sym[:ports]) + Array(sym[:port])).compact.map(&:to_s)
        out["ports"] = ports unless ports.empty?
        out
      end

      # Resolve a rule's destination (explicit kind+value, a {Destination} Hash,
      # or a shorthand String) onto the wire `out` Hash.
      def normalize_rule_destination(sym, out)
        if sym.key?(:destination_kind)
          out["destination_kind"] = sym[:destination_kind].to_s
          out["destination"] = sym[:destination].to_s unless sym[:destination].nil?
        elsif sym[:destination].is_a?(Hash)
          dest = sym[:destination].transform_keys(&:to_s)
          out["destination_kind"] = dest["destination_kind"].to_s if dest["destination_kind"]
          out["destination"] = dest["destination"].to_s if dest.key?("destination")
        elsif !sym[:destination].nil?
          out["destination"] = sym[:destination].to_s
        end
      end
    end

    def initialize(wire)
      @wire = wire
    end

    # @return [Hash] the normalized wire representation
    def to_h
      @wire
    end

    def inspect
      "#<Microsandbox::NetworkPolicy #{@wire.inspect}>"
    end
  end
end
