# frozen_string_literal: true

require "json"

# Exercises the pure-Ruby normalization and value objects for the v0.6.6 parity
# surface — modify / ping / touch — WITHOUT booting a real microVM, by stubbing
# the native layer. The native binding itself is exercised only by the
# environment-gated integration suite (spec/integration/modify_health_spec.rb);
# a green run here proves nothing about real-VM behavior.
RSpec.describe "v0.6.6 modify/ping/touch parity" do
  # A representative apply plan as the native layer serializes it (canonical
  # snake_case keys, literal-space enum strings), used to assert Ruby-side parsing.
  let(:plan_json) do
    JSON.generate(
      "sandbox" => "box",
      "status" => "running",
      "applied" => true,
      "policy" => "no_restart",
      "changes" => [
        {"kind" => "config", "field" => "cpus", "change" => "updated",
         "before" => "1", "after" => "2", "disposition" => "live"},
        {"kind" => "secret", "field" => "secret", "name" => "API_KEY",
         "change" => "hosts updated", "disposition" => "next start",
         "allow_hosts" => ["api.example.com"]}
      ],
      "conflicts" => [{"field" => "memory", "message" => "exceeds max_memory"}],
      "warnings" => [{"field" => "cpus", "message" => "guest may refuse"}],
      "resize_status" => [
        {"resource" => "cpus", "requested" => "2", "actual" => "2",
         "enforced" => "2", "state" => "applied"}
      ]
    )
  end

  describe Microsandbox::Sandbox do
    let(:native) { instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil) }
    let(:sandbox) { described_class.new(native) }

    describe "#modify option mapping" do
      before { allow(native).to receive(:modify).and_return(plan_json) }

      it "normalizes resource, env, label, and workdir kwargs into a string-keyed hash" do
        sandbox.modify(
          cpus: 2, max_cpus: 4, memory: 1024, max_memory: 2048,
          env: {:FOO => 1, "BAR" => :baz}, remove_env: [:DEBUG, "STALE"],
          labels: {team: "core"}, remove_labels: ["old"],
          workdir: "/srv"
        )

        expect(native).to have_received(:modify).with(
          hash_including(
            "cpus" => 2, "max_cpus" => 4, "memory" => 1024, "max_memory" => 2048,
            "env" => {"FOO" => "1", "BAR" => "baz"}, "remove_env" => ["DEBUG", "STALE"],
            "labels" => {"team" => "core"}, "remove_labels" => ["old"],
            "workdir" => "/srv", "policy" => "no_restart"
          )
        )
      end

      it "always sets a policy, defaulting to no_restart, and omits unspecified options" do
        sandbox.modify(cpus: 1)
        expect(native).to have_received(:modify).with({"cpus" => 1, "policy" => "no_restart"})
      end

      it "accepts a policy Symbol or String and maps it to the native string" do
        sandbox.modify(policy: :next_start)
        sandbox.modify(policy: "restart")
        expect(native).to have_received(:modify).with(hash_including("policy" => "next_start"))
        expect(native).to have_received(:modify).with(hash_including("policy" => "restart"))
      end

      it "rejects an unknown policy with a clear ArgumentError" do
        expect { sandbox.modify(policy: :reboot) }
          .to raise_error(ArgumentError, /policy: must be :no_restart, :next_start, or :restart/)
        expect(native).not_to have_received(:modify)
      end

      it "sets dry_run only when requested" do
        sandbox.modify(cpus: 1, dry_run: true)
        expect(native).to have_received(:modify).with(hash_including("dry_run" => true))
      end
    end

    describe "#modify secret normalization" do
      before { allow(native).to receive(:modify).and_return(plan_json) }

      it "normalizes a { name => spec } Hash into a name-sorted array of specs" do
        sandbox.modify(
          secrets: {
            "ZED" => {store: "vault://zed", placeholder: "<zed>"},
            "API_KEY" => {env: "HOST_API_KEY", allowed_hosts: ["api.example.com", :extra]}
          },
          remove_secrets: [:OLD, "GONE"]
        )

        expect(native).to have_received(:modify).with(
          hash_including(
            "secrets" => [
              {"name" => "API_KEY", "env" => "HOST_API_KEY",
               "allowed_hosts" => ["api.example.com", "extra"]},
              {"name" => "ZED", "store" => "vault://zed", "placeholder" => "<zed>"}
            ],
            "remove_secrets" => ["OLD", "GONE"]
          )
        )
      end

      it "carries a raw value spec through" do
        sandbox.modify(secrets: {"TOK" => {value: "s3cret"}})
        expect(native).to have_received(:modify).with(
          hash_including("secrets" => [{"name" => "TOK", "value" => "s3cret"}])
        )
      end

      it "rejects mutually-exclusive sources naming only the keys, never the value" do
        expect {
          sandbox.modify(secrets: {"TOK" => {env: "HOST", value: "s3cret"}})
        }.to raise_error(ArgumentError) { |e|
          expect(e.message).to match(/secret "TOK": .* are mutually exclusive/)
          expect(e.message).to include('"env"', '"value"')
          expect(e.message).not_to include("s3cret")
        }
        expect(native).not_to have_received(:modify)
      end

      it "rejects a non-Hash secrets option" do
        expect { sandbox.modify(secrets: [{env: "X"}]) }
          .to raise_error(ArgumentError, /secrets: must be a Hash/)
      end

      it "rejects a non-Hash spec without leaking its value into the message" do
        # The tempting-but-wrong `{ name => raw_value }` shorthand: on
        # Ruby < 3.3 an unguarded spec.key? call would embed the receiver —
        # the cleartext secret — in a NoMethodError.
        expect {
          sandbox.modify(secrets: {"API_KEY" => "sk-live-abc123"})
        }.to raise_error(ArgumentError) { |e|
          expect(e.message).to match(/secret "API_KEY": spec must be a Hash/)
          expect(e.message).not_to include("sk-live-abc123")
        }
        expect(native).not_to have_received(:modify)
      end

      it "rejects a Symbol/String key collision instead of sending duplicate specs" do
        # Both keys stringify to one secret name; duplicates bypass upstream's
        # fluent-API dedup and make the live value diverge from the persisted
        # config nondeterministically.
        expect {
          sandbox.modify(secrets: {:API_KEY => {value: "a"}, "API_KEY" => {value: "b"}})
        }.to raise_error(ArgumentError) { |e|
          expect(e.message).to match(/duplicate entries for "API_KEY"/)
          expect(e.message).not_to include("a\"", "b\"")
        }
        expect(native).not_to have_received(:modify)
      end
    end

    describe "#modify return value" do
      before { allow(native).to receive(:modify).and_return(plan_json) }

      it "parses the native JSON plan into a ModificationPlan" do
        plan = sandbox.modify(cpus: 2)
        expect(plan).to be_a(Microsandbox::ModificationPlan)
        expect(plan.sandbox).to eq("box")
        expect(plan.status).to eq("running")
        expect(plan.applied?).to be(true)
        expect(plan.policy).to eq(:no_restart)
      end
    end

    describe "#ping / #touch" do
      it "wraps the native ping hash in a PingResult (seconds + ms)" do
        allow(native).to receive(:ping).and_return("name" => "box", "latency_secs" => 0.25)
        result = sandbox.ping
        expect(result).to be_a(Microsandbox::PingResult)
        expect(result.name).to eq("box")
        expect(result.latency).to eq(0.25)
        expect(result.latency_ms).to eq(250.0)
      end

      it "wraps the native touch hash in a TouchResult" do
        allow(native).to receive(:touch).and_return("name" => "box", "activity_seq" => 42)
        result = sandbox.touch
        expect(result).to be_a(Microsandbox::TouchResult)
        expect(result.name).to eq("box")
        expect(result.activity_seq).to eq(42)
      end
    end
  end

  describe Microsandbox::SandboxHandle do
    let(:native) { instance_double(Microsandbox::Native::SandboxHandle) }
    let(:handle) { described_class.new(native) }

    it "delegates #modify through the shared builder and parses the plan" do
      allow(native).to receive(:modify).and_return(plan_json)
      plan = handle.modify(memory: 1024, policy: :restart)
      expect(native).to have_received(:modify).with(
        hash_including("memory" => 1024, "policy" => "restart")
      )
      expect(plan).to be_a(Microsandbox::ModificationPlan)
    end

    it "delegates #ping and #touch" do
      allow(native).to receive(:ping).and_return("name" => "box", "latency_secs" => 0.1)
      allow(native).to receive(:touch).and_return("name" => "box", "activity_seq" => 7)
      expect(handle.ping).to be_a(Microsandbox::PingResult)
      expect(handle.touch.activity_seq).to eq(7)
    end
  end

  describe Microsandbox::ModificationPlan do
    subject(:plan) { described_class.new(JSON.parse(plan_json)) }

    it "exposes typed top-level fields" do
      expect(plan.sandbox).to eq("box")
      expect(plan.status).to eq("running")
      expect(plan.applied?).to be(true)
      expect(plan.policy).to eq(:no_restart)
    end

    it "returns nested entries as frozen, symbol-keyed Hashes with values verbatim" do
      config_change = plan.changes.first
      expect(config_change).to eq(
        {kind: "config", field: "cpus", change: "updated",
         before: "1", after: "2", disposition: "live"}
      )
      expect(config_change).to be_frozen
      expect(plan.changes).to be_frozen

      secret_change = plan.changes.last
      # literal-space enum strings are preserved (not re-cased):
      expect(secret_change[:change]).to eq("hosts updated")
      expect(secret_change[:disposition]).to eq("next start")
      expect(secret_change[:allow_hosts]).to eq(["api.example.com"])
    end

    it "parses conflicts, warnings, and resize_status" do
      expect(plan.conflicts).to eq([{field: "memory", message: "exceeds max_memory"}])
      expect(plan.warnings).to eq([{field: "cpus", message: "guest may refuse"}])
      expect(plan.resize_status.first).to include(resource: "cpus", state: "applied")
    end

    it "treats an absent resize_status as an empty array (dry-run plans omit it)" do
      dry = described_class.new(
        "sandbox" => "box", "status" => "running", "applied" => false,
        "policy" => "next_start", "changes" => [], "conflicts" => [], "warnings" => []
      )
      expect(dry.applied?).to be(false)
      expect(dry.policy).to eq(:next_start)
      expect(dry.resize_status).to eq([])
    end
  end

  describe "error classes" do
    it "defines SandboxNotRunningError for the v0.6.6 not-running guard" do
      expect(Microsandbox::SandboxNotRunningError).to be < Microsandbox::Error
      expect(Microsandbox::SandboxNotRunningError.code).to eq("sandbox-not-running")
    end
  end
end
