# frozen_string_literal: true

# Unit coverage for the network-policy factories (Destination, Rule,
# NetworkPolicy) and their normalization into Sandbox.create options. The native
# parsing/enforcement is exercised by the integration specs.
RSpec.describe "network policy" do
  describe Microsandbox::Destination do
    it "builds each typed destination" do
      expect(described_class.any).to eq("destination_kind" => "any")
      expect(described_class.ip("1.1.1.1")).to eq("destination_kind" => "ip", "destination" => "1.1.1.1")
      expect(described_class.cidr("10.0.0.0/8")).to eq("destination_kind" => "cidr", "destination" => "10.0.0.0/8")
      expect(described_class.domain("a.com")).to eq("destination_kind" => "domain", "destination" => "a.com")
      expect(described_class.domain_suffix(".x")).to eq("destination_kind" => "domain_suffix", "destination" => ".x")
    end

    it "normalizes group names to the wire spelling" do
      expect(described_class.group(:link_local)).to eq("destination_kind" => "group", "destination" => "link-local")
      expect(described_class.group("public")).to eq("destination_kind" => "group", "destination" => "public")
    end
  end

  describe Microsandbox::Rule do
    it "builds an allow rule with a shorthand string destination" do
      r = described_class.allow(destination: "1.1.1.1", protocol: :tcp, port: "443")
      expect(r).to eq(
        "action" => "allow", "direction" => "egress",
        "destination" => "1.1.1.1", "protocols" => ["tcp"], "ports" => ["443"]
      )
    end

    it "merges a typed Destination hash" do
      r = described_class.deny(destination: Microsandbox::Destination.group(:metadata))
      expect(r).to eq(
        "action" => "deny", "direction" => "egress",
        "destination_kind" => "group", "destination" => "metadata"
      )
    end

    it "supports explicit direction and multiple protocols/ports" do
      r = described_class.allow(
        destination: "10.0.0.0/8", direction: :ingress,
        protocols: %i[tcp udp], ports: ["80", "8000-9000"]
      )
      expect(r["direction"]).to eq("ingress")
      expect(r["protocols"]).to eq(%w[tcp udp])
      expect(r["ports"]).to eq(["80", "8000-9000"])
    end

    it "omits protocol/port keys and destination when unset (any)" do
      r = described_class.deny
      expect(r).to eq("action" => "deny", "direction" => "egress")
    end

    it "builds the gateway-DNS rule pair (mirrors the core Rule::allow_dns/deny_dns)" do
      expect(described_class.allow_dns).to eq(
        "action" => "allow", "direction" => "egress",
        "destination_kind" => "group", "destination" => "host",
        "protocols" => %w[udp tcp], "ports" => ["53"]
      )
      expect(described_class.deny_dns).to eq(described_class.allow_dns.merge("action" => "deny"))
    end
  end

  describe Microsandbox::NetworkPolicy do
    it "produces bare-preset wire hashes for the surviving terminal presets" do
      expect(described_class.none.to_h).to eq("preset" => "none")
      expect(described_class.allow_all.to_h).to eq("preset" => "allow_all")
    end

    it "composes profiles into a profiles wire hash" do
      expect(described_class.from_profiles(:public).to_h).to eq("profiles" => ["public"])
      expect(described_class.from_profiles(:host, "private").to_h)
        .to eq("profiles" => %w[host private])
    end

    it "expresses an empty profile set as the explicit empty custom policy" do
      # from_profiles([]) upstream = deny-egress/allow-ingress with zero rules
      # (and no DNS); the wire carries that literally instead of an empty array.
      expect(described_class.from_profiles.to_h).to eq(
        "default_egress" => "deny", "default_ingress" => "allow", "rules" => []
      )
    end

    it "no longer defines the removed preset factories" do
      expect(described_class).not_to respond_to(:public_only)
      expect(described_class).not_to respond_to(:non_local)
    end

    it "rejects removed v0.6.6 preset names with migration guidance" do
      expect { described_class.preset(:public_only) }
        .to raise_error(ArgumentError, /removed in runtime v0\.6\.7.*\[:public\]/m)
      expect { described_class.preset("non_local") }
        .to raise_error(ArgumentError, /\[:public, :private\]/)
      expect { described_class.from_profiles(:non_local) }
        .to raise_error(ArgumentError, /removed v0\.6\.6 network preset.*\[:public, :private\]/m)
    end

    it "builds a custom policy with defaults, rules, and bulk denials" do
      policy = described_class.custom(
        default_egress: :deny, default_ingress: :allow,
        rules: [Microsandbox::Rule.allow(destination: "api.openai.com", protocol: :tcp, port: "443")],
        deny_domain_suffixes: [".ads.example"]
      )
      expect(policy.to_h).to eq(
        "default_egress" => "deny",
        "default_ingress" => "allow",
        "rules" => [
          {"action" => "allow", "direction" => "egress",
           "destination" => "api.openai.com", "protocols" => ["tcp"], "ports" => ["443"]}
        ],
        "deny_domain_suffixes" => [".ads.example"]
      )
    end

    it "rejects an unknown preset alias" do
      expect { described_class.preset("bogus") }.to raise_error(ArgumentError, /unknown network preset/)
      expect { described_class.from_profiles(:bogus) }
        .to raise_error(ArgumentError, /unknown network profile/)
    end

    it "rejects an invalid action" do
      expect { described_class.custom(default_egress: :maybe) }.to raise_error(ArgumentError, /:allow or :deny/)
    end

    it "canonicalizes a hand-written rule's singular protocol/port to plural arrays" do
      # Regression: a plain-Hash rule using the singular protocol/port keys (the
      # spelling Go/Python's PolicyRule use) must not be dropped — that would widen
      # an `allow tcp/443` rule into an all-protocol/all-port allow.
      policy = described_class.custom(
        rules: [{action: "allow", destination: "1.1.1.1", protocol: "tcp", port: "443"}]
      )
      expect(policy.to_h["rules"]).to eq(
        [{"action" => "allow", "destination" => "1.1.1.1", "protocols" => ["tcp"], "ports" => ["443"]}]
      )
    end

    it "accepts a typed Destination hash inside a hand-written rule" do
      policy = described_class.custom(
        rules: [{action: "deny", destination: Microsandbox::Destination.group(:metadata)}]
      )
      expect(policy.to_h["rules"]).to eq(
        [{"action" => "deny", "destination_kind" => "group", "destination" => "metadata"}]
      )
    end
  end

  describe "Sandbox.create routing" do
    let(:native) { instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil) }

    before do
      allow(Microsandbox::Native::Sandbox).to receive(:create).and_return(native)
      allow(Microsandbox).to receive(:ensure_runtime!)
    end

    it "routes a bare preset symbol to the legacy network key" do
      Microsandbox::Sandbox.create("box", image: "x", network: :allow_all)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("network" => "allow_all")
      )
    end

    it "routes a profile Array to network_profiles" do
      Microsandbox::Sandbox.create("box", image: "x", network: [:public, :private])
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("network_profiles" => %w[public private])
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_excluding("network", "network_policy")
      )
    end

    it "routes a single profile Symbol (and :default) to network_profiles" do
      Microsandbox::Sandbox.create("box", image: "x", network: :host)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("network_profiles" => ["host"])
      )
      # :default is still accepted and is exactly the :public profile.
      Microsandbox::Sandbox.create("box2", image: "x", network: :default)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box2", hash_including("network_profiles" => ["public"])
      )
    end

    it "routes a profiles-plus-extras Hash to network_policy with a profiles base" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        network: {profiles: [:public], deny_domains: ["evil.com"]}
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("network_policy" => {"profiles" => ["public"], "deny_domains" => ["evil.com"]})
      )
    end

    it "rejects combining profiles: with preset: and removed presets everywhere" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", network: {profiles: [:public], preset: :none})
      end.to raise_error(ArgumentError, /mutually exclusive/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x", network: :public_only)
      end.to raise_error(ArgumentError, /removed in runtime v0\.6\.7/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x", network: [:non_local])
      end.to raise_error(ArgumentError, /removed v0\.6\.6 network preset/)
    end

    it "routes a NetworkPolicy object to network_policy" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        network: Microsandbox::NetworkPolicy.custom(
          rules: [Microsandbox::Rule.deny(destination: "evil.com")]
        )
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "network_policy" => hash_including(
            "default_egress" => "deny",
            "rules" => [{"action" => "deny", "direction" => "egress", "destination" => "evil.com"}]
          )
        )
      )
    end

    it "routes a plain Hash to network_policy" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        network: {default_egress: :deny, rules: [{action: "allow", destination: "1.1.1.1"}]}
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "network_policy" => hash_including(
            "default_egress" => "deny",
            "rules" => [{"action" => "allow", "destination" => "1.1.1.1"}]
          )
        )
      )
    end

    it "routes a preset-plus-deny-domains hash to network_policy without injecting defaults" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        network: {preset: :allow_all, deny_domains: ["evil.com"]}
      )
      # Crucially: no default_egress/default_ingress is injected, so the native
      # layer applies the preset's own defaults (regression: injected defaults
      # used to clobber the preset, turning allow_all into deny-all egress).
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("network_policy" => {"preset" => "allow_all", "deny_domains" => ["evil.com"]})
      )
    end

    it "routes a bare preset Hash to the legacy network key (preset defaults preserved)" do
      Microsandbox::Sandbox.create("box", image: "x", network: {preset: :allow_all})
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("network" => "allow_all")
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_excluding("network_policy")
      )
    end

    it "rejects combining a preset with custom rules or defaults" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", network: {preset: :allow_all, rules: []})
      end.to raise_error(ArgumentError, /preset:.*cannot be combined/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x", network: {preset: :none, default_ingress: :deny})
      end.to raise_error(ArgumentError, /preset:.*cannot be combined/)
    end

    it "treats a deny-list-only hash as permissive (block listed domains, allow the rest)" do
      # Regression: { deny_domains: [...] } with no preset/defaults must keep the
      # rest of the network reachable, not deny all unmatched egress.
      Microsandbox::Sandbox.create("box", image: "x", network: {deny_domains: ["evil.com"]})
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "network_policy" => {
            "default_egress" => "allow", "default_ingress" => "allow", "deny_domains" => ["evil.com"]
          }
        )
      )
    end

    it "treats an empty network hash as a no-op (leaves the default policy)" do
      Microsandbox::Sandbox.create("box", image: "x", network: {})
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_excluding("network", "network_policy")
      )
    end

    it "still omits network entirely when not given" do
      Microsandbox::Sandbox.create("box", image: "x")
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with("box", {"image" => "x"})
    end
  end
end
