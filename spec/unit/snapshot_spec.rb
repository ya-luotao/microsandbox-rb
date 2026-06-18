# frozen_string_literal: true

# Pure-Ruby option-normalization + value-object coverage for Microsandbox::Snapshot.
# The native layer is stubbed; real behaviour is exercised by the integration specs.
RSpec.describe Microsandbox::Snapshot do
  describe ".create" do
    it "normalizes destination/labels/flags into a string-keyed options hash" do
      allow(Microsandbox::Native::Snapshot).to receive(:create).and_return(
        "digest" => "sha256:abc", "path" => "/snaps/x", "size_bytes" => 2048
      )
      info = described_class.create("box", name: "snap1", labels: {kind: :base},
        force: true, record_integrity: true)
      expect(Microsandbox::Native::Snapshot).to have_received(:create).with(
        "box",
        hash_including("name" => "snap1", "labels" => {"kind" => "base"},
          "force" => true, "record_integrity" => true)
      )
      expect(info).to be_a(Microsandbox::SnapshotInfo)
      expect(info.digest).to eq("sha256:abc")
      expect(info.size_bytes).to eq(2048)
    end

    it "passes path when given instead of name" do
      allow(Microsandbox::Native::Snapshot).to receive(:create).and_return(
        "digest" => "sha256:abc", "path" => "/tmp/snap"
      )
      described_class.create("box", path: "/tmp/snap")
      expect(Microsandbox::Native::Snapshot).to have_received(:create).with(
        "box", hash_including("path" => "/tmp/snap")
      )
    end
  end

  describe ".list / .get" do
    it "wraps handles in SnapshotInfo with parsed format and timestamp" do
      allow(Microsandbox::Native::Snapshot).to receive(:list).and_return(
        [{"digest" => "sha256:d", "path" => "/p", "name" => "s", "image_ref" => "alpine",
          "format" => "qcow2", "size_bytes" => 10, "created_at_ms" => 1_700_000_000_000}]
      )
      info = described_class.list.first
      expect(info.name).to eq("s")
      expect(info.format).to eq(:qcow2)
      expect(info.created_at).to be_a(Time)
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
      expect(report.algorithm).to eq("sha256")
      expect(report.content_digest).to eq("deadbeef")
    end

    it "maps a not-recorded report" do
      allow(Microsandbox::Native::Snapshot).to receive(:verify).and_return(
        "digest" => "sha256:d", "path" => "/p", "upper_status" => "not_recorded"
      )
      expect(described_class.verify("snap1")).to be_not_recorded
    end
  end

  describe ".remove / .export / .import" do
    it "forwards remove with the force flag" do
      allow(Microsandbox::Native::Snapshot).to receive(:remove)
      described_class.remove("snap1", force: true)
      expect(Microsandbox::Native::Snapshot).to have_received(:remove).with("snap1", true)
    end

    it "normalizes export flags" do
      allow(Microsandbox::Native::Snapshot).to receive(:export)
      described_class.export("snap1", "/tmp/out.tar.zst", with_parents: true, with_image: true)
      expect(Microsandbox::Native::Snapshot).to have_received(:export).with(
        "snap1", "/tmp/out.tar.zst", hash_including("with_parents" => true, "with_image" => true)
      )
    end

    it "passes an optional dest to import" do
      allow(Microsandbox::Native::Snapshot).to receive(:import).and_return(
        "digest" => "sha256:d", "path" => "/p"
      )
      described_class.import("/tmp/a.tar.zst", dest: "/snaps")
      expect(Microsandbox::Native::Snapshot).to have_received(:import).with("/tmp/a.tar.zst", "/snaps")
    end
  end
end
