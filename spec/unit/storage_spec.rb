# frozen_string_literal: true

require "json"

# Storage diagnosis and recovery (runtime v0.7) are JSON bridges over the
# core's own wire types; these specs stub the native layer and pin what the
# Ruby layer sends and how it shapes the report.
RSpec.describe "storage diagnosis and recovery" do
  let(:native) { Microsandbox::Native::Storage }

  describe "Microsandbox.diagnose_storage" do
    let(:report) do
      {
        "home" => "/h",
        "required_runtime_capability" => "protected-storage-v1",
        "sandboxes" => [
          {"name" => "old", "status" => "maintenance_required", "running" => false,
           "protection_registered" => false, "reason" => nil,
           "guest_mounts" => {"data" => "/data"}, "future_field" => 1,
           "inspection" => {"status" => "eligible", "reasons" => ["legacy layout"],
                            "estimated_bytes" => 4096, "preview_available" => true,
                            "candidates" => [{"id" => "c1", "disk_id" => "root", "layers" => 2,
                                              "virtual_size" => 1 << 30, "estimated_bytes" => 4096}]}},
          {"name" => "gone", "status" => "unavailable", "running" => false,
           "protection_registered" => false, "reason" => "not_found", "inspection" => nil}
        ]
      }
    end

    before { allow(native).to receive(:diagnose_json).and_return(JSON.generate(report)) }

    it "sends a named scope and an empty config" do
      Microsandbox.diagnose_storage(names: ["old", :gone])
      expect(native).to have_received(:diagnose_json).with("{}", JSON.generate({"named" => %w[old gone]}))
    end

    it "accepts a single name" do
      Microsandbox.diagnose_storage(names: "old")
      expect(native).to have_received(:diagnose_json).with("{}", '{"named":["old"]}')
    end

    it "sends the all scope and a home override" do
      Microsandbox.diagnose_storage(all_sandboxes: true, home: "/srv/msb")
      expect(native).to have_received(:diagnose_json).with('{"home":"/srv/msb"}', '"all"')
    end

    it "requires exactly one scope" do
      expect { Microsandbox.diagnose_storage }.to raise_error(ArgumentError, /exactly one/)
      expect { Microsandbox.diagnose_storage(names: ["a"], all_sandboxes: true) }
        .to raise_error(ArgumentError, /exactly one/)
      expect { Microsandbox.diagnose_storage(names: []) }.to raise_error(ArgumentError, /must not be empty/)
      expect(native).not_to have_received(:diagnose_json)
    end

    it "shapes the report into value objects" do
      diagnosis = Microsandbox.diagnose_storage(all_sandboxes: true)
      expect(diagnosis).to be_a(Microsandbox::StorageDiagnosis)
      expect(diagnosis.home).to eq("/h")
      expect(diagnosis.required_runtime_capability).to eq("protected-storage-v1")

      old, gone = diagnosis.sandboxes
      expect(old.name).to eq("old")
      expect(old.status).to eq(:maintenance_required)
      expect(old.reason).to be_nil
      expect(old.running?).to be(false)
      expect(old.protection_registered?).to be(false)
      expect(old.guest_mounts).to eq({"data" => "/data"})
      expect(old.inspection.status).to eq(:eligible)
      expect(old.inspection.reasons).to eq(["legacy layout"])
      expect(old.inspection.estimated_bytes).to eq(4096)
      expect(old.inspection.preview_available?).to be(true)
      candidate = old.inspection.candidates.first
      expect([candidate.id, candidate.disk_id, candidate.layers, candidate.virtual_size, candidate.estimated_bytes])
        .to eq(["c1", "root", 2, 1 << 30, 4096])

      expect(gone.status).to eq(:unavailable)
      expect(gone.reason).to eq(:not_found)
      expect(gone.inspection).to be_nil
      expect(gone.guest_mounts).to eq({})
      expect(diagnosis.inspect).to include("old", "gone")
    end

    it "does not need the runtime" do
      allow(Microsandbox).to receive(:ensure_runtime!)
      Microsandbox.diagnose_storage(names: ["old"])
      expect(Microsandbox).not_to have_received(:ensure_runtime!)
    end
  end

  describe "Microsandbox::Sandbox.recover_storage" do
    before do
      allow(Microsandbox).to receive(:ensure_runtime!)
      allow(native).to receive(:recover_json)
        .and_return('{"name":"old","ready":true,"originals_retained":true}')
    end

    def sent_options
      options = nil
      expect(native).to have_received(:recover_json) { |_name, json| options = JSON.parse(json) }
      options
    end

    it "sends the default options and returns a StorageRecovery" do
      result = Microsandbox::Sandbox.recover_storage(:old)
      expect(native).to have_received(:recover_json).with("old", anything)
      expect(sent_options).to eq({"selections" => [], "accept_selected_view" => false,
                                  "legacy_writers_stopped" => false})
      expect(result).to be_a(Microsandbox::StorageRecovery)
      expect(result.name).to eq("old")
      expect(result.ready?).to be(true)
      expect(result.originals_retained?).to be(true)
    end

    it "maps selections to disk/candidate pairs and passes the confirmations" do
      Microsandbox::Sandbox.recover_storage("old", selections: {:root => "c1", "data" => :c2},
        accept_selected_view: true, legacy_writers_stopped: true)
      expect(sent_options).to eq({
        "selections" => [{"disk_id" => "root", "candidate_id" => "c1"},
          {"disk_id" => "data", "candidate_id" => "c2"}],
        "accept_selected_view" => true, "legacy_writers_stopped" => true
      })
    end

    it "only treats true as a confirmation" do
      Microsandbox::Sandbox.recover_storage("old", legacy_writers_stopped: "yes")
      expect(sent_options["legacy_writers_stopped"]).to be(false)
    end

    it "checks the runtime before recovering" do
      Microsandbox::Sandbox.recover_storage("old")
      expect(Microsandbox).to have_received(:ensure_runtime!).ordered
      expect(native).to have_received(:recover_json).ordered
    end

    it "rejects non-Hash selections before touching the runtime" do
      expect { Microsandbox::Sandbox.recover_storage("old", selections: [["root", "c1"]]) }
        .to raise_error(ArgumentError, /selections: must be a Hash/)
      expect(Microsandbox).not_to have_received(:ensure_runtime!)
      expect(native).not_to have_received(:recover_json)
    end
  end
end
