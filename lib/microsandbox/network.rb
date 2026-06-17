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
    def any = { "destination_kind" => "any" }

    # A single IP address (stored as a /32 or /128).
    def ip(value) = { "destination_kind" => "ip", "destination" => value.to_s }

    # An IP network in CIDR notation (e.g. "10.0.0.0/8").
    def cidr(value) = { "destination_kind" => "cidr", "destination" => value.to_s }

    # An exact domain name (matched against the resolved-hostname cache / SNI).
    def domain(value) = { "destination_kind" => "domain", "destination" => value.to_s }

    # A domain suffix — matches the apex and any subdomain (e.g. ".internal").
    def domain_suffix(value) = { "destination_kind" => "domain_suffix", "destination" => value.to_s }

    # A predefined group: :public, :loopback, :private, :link_local, :metadata,
    # :multicast, or :host.
    def group(value) = { "destination_kind" => "group", "destination" => value.to_s.tr("_", "-") }
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

    # @api private
    def build(action, destination, direction, protocol, protocols, port, ports)
      rule = { "action" => action, "direction" => direction.to_s }
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
      when String, Symbol then { "destination" => dest.to_s }
      else raise ArgumentError, "invalid rule destination: #{dest.inspect}"
      end
    end
  end

  # A sandbox network policy: a preset, or a custom set of allow/deny {Rule}s
  # with per-direction default actions and bulk domain denials.
  #
  # Pass to {Sandbox.create} via `network:` — either a {NetworkPolicy}, a preset
  # name (String/Symbol), or a plain Hash with the same keys as {custom}.
  #
  # @example presets
  #   Sandbox.create("b", image: "alpine", network: NetworkPolicy.public_only)
  #   Sandbox.create("b", image: "alpine", network: :none)
  #
  # @example custom
  #   policy = Microsandbox::NetworkPolicy.custom(
  #     default_egress: :deny,
  #     rules: [
  #       Microsandbox::Rule.allow(destination: "api.openai.com", protocol: :tcp, port: "443"),
  #     ],
  #     deny_domain_suffixes: [".ads.example"],
  #   )
  #   Sandbox.create("b", image: "alpine", network: policy)
  #
  # Mirrors `NetworkPolicy` / `Network` in the official Python/Node/Go SDKs.
  class NetworkPolicy
    # Canonical preset names keyed by every accepted alias.
    PRESET_ALIASES = {
      "none" => "none", "disabled" => "none", "disable" => "none", "airgapped" => "none",
      "public" => "public_only", "public_only" => "public_only", "public-only" => "public_only",
      "default" => "public_only",
      "all" => "allow_all", "allow_all" => "allow_all", "allow-all" => "allow_all",
      "non_local" => "non_local", "non-local" => "non_local", "nonlocal" => "non_local"
    }.freeze

    class << self
      # @return [NetworkPolicy] allow only public internet (the default)
      def public_only = preset("public_only")

      # @return [NetworkPolicy] block all network access
      def none = preset("none")

      # @return [NetworkPolicy] permit all traffic
      def allow_all = preset("allow_all")

      # @return [NetworkPolicy] allow public internet plus private/LAN egress
      def non_local = preset("non_local")

      # @return [NetworkPolicy] a bare preset policy
      def preset(name)
        new("preset" => canonical_preset(name))
      end

      # Build a custom policy — an ordered rule list with per-direction default
      # actions. A custom policy stands on its own (no preset); to start from a
      # preset, use the preset factories (optionally with `deny_domains:` via the
      # Hash form passed to {Sandbox.create}). `preset:` and custom rules/defaults
      # are mutually exclusive, mirroring the official SDKs.
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
        when String, Symbol then { "preset" => canonical_preset(network) }
        when Hash then from_hash(network)
        else
          raise ArgumentError,
                "network: expects a preset name, a Microsandbox::NetworkPolicy, or a Hash " \
                "(got #{network.class})"
        end
      end

      private

      # A `network:` Hash is either a preset (`preset:` + optional deny lists) or
      # a custom policy (`default_egress:`/`default_ingress:`/`rules:` + optional
      # deny lists). The two are mutually exclusive: a preset already defines its
      # rules and defaults, so layering custom rules/defaults on top would silently
      # override them (and diverge from the official SDKs, where preset and custom
      # are separate paths). A bare preset (only `preset:`, no deny lists) is
      # routed to the preset path by {Sandbox.create}, so its own defaults apply.
      def from_hash(hash)
        sym = hash.transform_keys(&:to_sym)
        if sym.key?(:preset)
          if sym.key?(:rules) || sym.key?(:default_egress) || sym.key?(:default_ingress)
            raise ArgumentError,
                  "network preset: cannot be combined with rules:/default_egress:/" \
                  "default_ingress: (the preset already defines its rules and defaults); " \
                  "only deny_domains:/deny_domain_suffixes: may be layered on a preset"
          end
          h = { "preset" => canonical_preset(sym[:preset]) }
          add_deny_lists(h, sym[:deny_domains], sym[:deny_domain_suffixes])
          h
        else
          custom(
            default_egress: sym.fetch(:default_egress, :deny),
            default_ingress: sym.fetch(:default_ingress, :allow),
            rules: sym[:rules] || [],
            deny_domains: sym[:deny_domains] || [],
            deny_domain_suffixes: sym[:deny_domain_suffixes] || []
          ).to_h
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
        PRESET_ALIASES[key] ||
          raise(ArgumentError,
                "unknown network preset #{name.inspect} " \
                "(expected one of public_only/none/allow_all/non_local)")
      end

      def action_str(action)
        case action.to_s.downcase
        when "allow" then "allow"
        when "deny" then "deny"
        else raise ArgumentError, "network action must be :allow or :deny (got #{action.inspect})"
        end
      end

      def normalize_rule(rule)
        unless rule.is_a?(Hash)
          raise ArgumentError, "rule must be a Hash (use Microsandbox::Rule.allow/deny): #{rule.inspect}"
        end
        rule.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
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
