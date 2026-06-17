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
  end

  describe Microsandbox::NetworkPolicy do
    it "produces bare-preset wire hashes" do
      expect(described_class.public_only.to_h).to eq("preset" => "public_only")
      expect(described_class.none.to_h).to eq("preset" => "none")
      expect(described_class.allow_all.to_h).to eq("preset" => "allow_all")
      expect(described_class.non_local.to_h).to eq("preset" => "non_local")
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
          { "action" => "allow", "direction" => "egress",
            "destination" => "api.openai.com", "protocols" => ["tcp"], "ports" => ["443"] },
        ],
        "deny_domain_suffixes" => [".ads.example"]
      )
    end

    it "rejects an unknown preset alias" do
      expect { described_class.public_only }.not_to raise_error
      expect { described_class.preset("bogus") }.to raise_error(ArgumentError, /unknown network preset/)
    end

    it "rejects an invalid action" do
      expect { described_class.custom(default_egress: :maybe) }.to raise_error(ArgumentError, /:allow or :deny/)
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
            "rules" => [{ "action" => "deny", "direction" => "egress", "destination" => "evil.com" }]
          )
        )
      )
    end

    it "routes a plain Hash to network_policy" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        network: { default_egress: :deny, rules: [{ action: "allow", destination: "1.1.1.1" }] }
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "network_policy" => hash_including(
            "default_egress" => "deny",
            "rules" => [{ "action" => "allow", "destination" => "1.1.1.1" }]
          )
        )
      )
    end

    it "routes a preset-plus-deny-domains hash to network_policy without injecting defaults" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        network: { preset: :public_only, deny_domains: ["evil.com"] }
      )
      # Crucially: no default_egress/default_ingress is injected, so the native
      # layer applies the preset's own defaults (regression: injected defaults
      # used to clobber the preset, turning allow_all into deny-all egress).
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("network_policy" => { "preset" => "public_only", "deny_domains" => ["evil.com"] })
      )
    end

    it "routes a bare preset Hash to the legacy network key (preset defaults preserved)" do
      Microsandbox::Sandbox.create("box", image: "x", network: { preset: :allow_all })
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("network" => "allow_all")
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_excluding("network_policy")
      )
    end

    it "rejects combining a preset with custom rules or defaults" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", network: { preset: :public_only, rules: [] })
      end.to raise_error(ArgumentError, /preset:.*cannot be combined/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x", network: { preset: :none, default_ingress: :deny })
      end.to raise_error(ArgumentError, /preset:.*cannot be combined/)
    end

    it "still omits network entirely when not given" do
      Microsandbox::Sandbox.create("box", image: "x")
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with("box", { "image" => "x" })
    end
  end
end
