# frozen_string_literal: true

# Real microVM integration coverage for snapshots and pull policy.
# Opt-in via MICROSANDBOX_INTEGRATION=1.
RSpec.describe "snapshots + pull policy", :integration do
  let(:image) { default_test_image }

  it "snapshots a stopped sandbox and boots a new one from it" do
    src = unique_sandbox_name("rb-snapsrc")
    snap = "rb-snap-#{Process.pid}-#{rand(100_000)}"
    marker = "snap-data-#{rand(1_000_000)}"
    begin
      sb = Microsandbox::Sandbox.create(src, image: image)
      sb.fs.write("/root/marker.txt", marker)
      sb.stop

      # v0.6.9: payload integrity is opt-in — record it here so the verify
      # below exercises the :verified path.
      info = Microsandbox::Snapshot.create(snap, from_sandbox: src, record_integrity: true)
      expect(info).to be_a(Microsandbox::SnapshotInfo)
      expect(info.digest).to start_with("sha256:")
      expect(info.scope).to eq(:disk)
      expect(info.state_kind).to eq("file")
      expect(Microsandbox::Snapshot.list.map(&:name)).to include(snap)

      report = Microsandbox::Snapshot.verify(snap)
      expect(report).to be_a(Microsandbox::SnapshotVerifyReport)
      expect(report).to be_verified
      expect(report.algorithm).not_to be_nil

      Microsandbox::Sandbox.create(unique_sandbox_name("rb-snapboot"), from_snapshot: snap) do |sb2|
        expect(sb2.fs.read_text("/root/marker.txt")).to eq(marker)
      end

      # Archive round-trip via the renamed save/load: save the artifact,
      # remove the original, load it back, and confirm the same identity.
      require "tmpdir"
      Dir.mktmpdir do |dir|
        archive = File.join(dir, "snap.tar.zst")
        Microsandbox::Snapshot.save(snap, archive)
        expect(File.size(archive)).to be > 0

        Microsandbox::Snapshot.remove(snap, force: true)
        loaded = Microsandbox::Snapshot.load(archive)
        # Digest identity is what load guarantees (mirrors upstream's own
        # round-trip tests): the name alias is an index-level property that
        # `remove` already dropped, so the loaded artifact re-registers by
        # digest only.
        expect(loaded.digest).to eq(info.digest)
        expect(Microsandbox::Snapshot.list.map(&:digest)).to include(info.digest)
      end
    ensure
      begin
        Microsandbox::Snapshot.remove(snap, force: true)
      rescue
        Microsandbox::Error
      end
      # The loaded copy is indexed by digest (its name alias is gone) — remove
      # it by digest so a run doesn't leak the re-imported artifact.
      begin
        Microsandbox::Snapshot.remove(info.digest, force: true) if info
      rescue
        Microsandbox::Error
      end
      begin
        Microsandbox::Sandbox.remove(src)
      rescue
        Microsandbox::Error
      end
    end
  end

  # v0.6.9 breaking change: without record_integrity: true no content digest
  # is recorded, and verify reports :not_recorded instead of :verified.
  it "reports :not_recorded for a snapshot created without record_integrity" do
    src = unique_sandbox_name("rb-snapnorec")
    snap = "rb-snapnorec-#{Process.pid}-#{rand(100_000)}"
    begin
      sb = Microsandbox::Sandbox.create(src, image: image)
      sb.stop

      Microsandbox::Snapshot.create(snap, from_sandbox: src)
      report = Microsandbox::Snapshot.verify(snap)
      expect(report).not_to be_verified
      expect(report.status).to eq(:not_recorded)
      expect(report.algorithm).to be_nil
      expect(report.content_digest).to be_nil
    ensure
      begin
        Microsandbox::Snapshot.remove(snap, force: true)
      rescue
        Microsandbox::Error
      end
      begin
        Microsandbox::Sandbox.remove(src)
      rescue
        Microsandbox::Error
      end
    end
  end

  it "boots with pull_policy: never from the local cache" do
    # Warm the cache first: with randomized ordering this example can run before
    # any other spec has pulled the image, and `never` must not hit a registry.
    unless Microsandbox::Image.list.map(&:reference).include?(image)
      Microsandbox::Sandbox.create(unique_sandbox_name, image: image) { |sb| sb.exec("true") }
    end
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image, pull_policy: "never") do |sb|
      expect(sb.exec("true")).to be_success
    end
  end
end
