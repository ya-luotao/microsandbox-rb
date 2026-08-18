# frozen_string_literal: true

# Pure-Ruby option-normalization + value-object coverage for Microsandbox::Snapshot.
# The native layer is stubbed; real behaviour is exercised by the integration specs.
RSpec.describe Microsandbox::Snapshot do
  describe ".create" do
    it "keys the call by snapshot name and normalizes source/labels/flags" do
      allow(Microsandbox::Native::Snapshot).to receive(:create).and_return(
        "digest" => "sha256:abc", "path" => "/snaps/snap1", "size_bytes" => 2048
      )
      info = described_class.create("snap1", from_sandbox: "box", labels: {kind: :base},
        force: true, record_integrity: true)
      expect(Microsandbox::Native::Snapshot).to have_received(:create).with(
        "snap1",
        hash_including("from_sandbox" => "box", "labels" => {"kind" => "base"},
          "force" => true, "record_integrity" => true)
      )
      expect(info).to be_a(Microsandbox::SnapshotInfo)
      expect(info.digest).to eq("sha256:abc")
      expect(info.size_bytes).to eq(2048)
    end

    it "passes dest_dir (the parent directory) and the resumable flag" do
      allow(Microsandbox::Native::Snapshot).to receive(:create).and_return(
        "digest" => "sha256:abc", "path" => "/tmp/snaps/snap1"
      )
      described_class.create("snap1", from_sandbox: "box", dest_dir: "/tmp/snaps", resumable: true)
      expect(Microsandbox::Native::Snapshot).to have_received(:create).with(
        "snap1", hash_including("dest_dir" => "/tmp/snaps", "resumable" => true)
      )
    end

    it "requires from_sandbox as a keyword" do
      expect { described_class.create("snap1") }.to raise_error(ArgumentError)
    end
  end

  describe ".list / .get" do
    it "wraps handles in SnapshotInfo with parsed format, scope, and timestamp" do
      allow(Microsandbox::Native::Snapshot).to receive(:list).and_return(
        [{"digest" => "sha256:d", "path" => "/p", "name" => "s", "image_ref" => "alpine",
          "format" => "qcow2", "size_bytes" => 10, "created_at_ms" => 1_700_000_000_000,
          "scope" => "disk", "state_kind" => "file", "locality" => "embedded",
          "availability" => "ready", "migration_state" => "canonical"}]
      )
      info = described_class.list.first
      expect(info.name).to eq("s")
      expect(info.format).to eq(:qcow2)
      expect(info.scope).to eq(:disk)
      expect(info.state_kind).to eq("file")
      expect(info.locality).to eq("embedded")
      expect(info.availability).to eq("ready")
      expect(info.migration_state).to eq("canonical")
      expect(info.migration_error_code).to be_nil
      expect(info.created_at).to be_a(Time)
    end

    it "leaves file-state fields nil for a checkpoint-state snapshot" do
      allow(Microsandbox::Native::Snapshot).to receive(:get).and_return(
        "digest" => "sha256:d", "path" => "/p", "scope" => "resumable",
        "state_kind" => "checkpoint", "format" => nil, "fstype" => nil,
        "size_bytes" => nil, "checkpoint_manifest_digest" => "sha256:cp"
      )
      info = described_class.get("snap1")
      expect(info.format).to be_nil
      expect(info.fstype).to be_nil
      expect(info.size_bytes).to be_nil
      expect(info.scope).to eq(:resumable)
      expect(info.state_kind).to eq("checkpoint")
      expect(info.checkpoint_manifest_digest).to eq("sha256:cp")
    end
  end

  describe ".verify" do
    it "maps a verified report" do
      allow(Microsandbox::Native::Snapshot).to receive(:verify).and_return(
        "digest" => "sha256:d", "path" => "/p", "upper_status" => "verified",
        "upper_algorithm" => "sha256", "upper_digest" => "deadbeef"
      )
      report = described_class.verify("snap1")
      expect(report).to be_verified
      expect(report.status).to eq(:verified)
      expect(report.algorithm).to eq("sha256")
      expect(report.content_digest).to eq("deadbeef")
    end

    # v0.6.9 (#1346): payload integrity is opt-in at create time; without
    # `record_integrity: true` the report carries no content digest.
    it "maps a not-recorded report" do
      allow(Microsandbox::Native::Snapshot).to receive(:verify).and_return(
        "digest" => "sha256:d", "path" => "/p", "upper_status" => "not_recorded"
      )
      report = described_class.verify("snap1")
      expect(report).not_to be_verified
      expect(report.status).to eq(:not_recorded)
      expect(report.algorithm).to be_nil
      expect(report.content_digest).to be_nil
    end
  end

  describe ".remove / .save / .load" do
    it "forwards remove with the force flag" do
      allow(Microsandbox::Native::Snapshot).to receive(:remove)
      described_class.remove("snap1", force: true)
      expect(Microsandbox::Native::Snapshot).to have_received(:remove).with("snap1", true)
    end

    it "normalizes save flags (renamed from export)" do
      allow(Microsandbox::Native::Snapshot).to receive(:save)
      described_class.save("snap1", "/tmp/out.tar.zst", with_parents: true, with_image: true)
      expect(Microsandbox::Native::Snapshot).to have_received(:save).with(
        "snap1", "/tmp/out.tar.zst", hash_including("with_parents" => true, "with_image" => true)
      )
    end

    it "passes an optional dest to load (renamed from import)" do
      allow(Microsandbox::Native::Snapshot).to receive(:load).and_return(
        "digest" => "sha256:d", "path" => "/p"
      )
      described_class.load("/tmp/a.tar.zst", dest: "/snaps")
      expect(Microsandbox::Native::Snapshot).to have_received(:load).with("/tmp/a.tar.zst", "/snaps")
    end

    it "no longer defines export/import" do
      expect(described_class).not_to respond_to(:export)
      expect(described_class).not_to respond_to(:import)
    end
  end
end
