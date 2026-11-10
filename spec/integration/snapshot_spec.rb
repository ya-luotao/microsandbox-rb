# frozen_string_literal: true

# Real microVM integration coverage for snapshots and pull policy.
# Opt-in via MICROSANDBOX_INTEGRATION=1.
RSpec.describe "snapshots + pull policy", :integration do
  let(:image) { default_test_image }

  it "snapshots a stopped sandbox, verifies it and round-trips its archive" do
    src = unique_sandbox_name("rb-snapsrc")
    snap = "rb-snap-#{Process.pid}-#{rand(100_000)}"
    marker = "snap-data-#{rand(1_000_000)}"
    info = nil
    loaded = nil
    begin
      sb = Microsandbox::Sandbox.create(src, image: image)
      sb.fs.write("/root/marker.txt", marker)
      sb.stop

      # v0.6.9: payload integrity is opt-in — record it here so the verify
      # below exercises the :verified path.
      info = Microsandbox::Snapshot.create(snap, from_sandbox: src, record_integrity: true)
      expect(info).to be_a(Microsandbox::SnapshotInfo)
      expect(info.digest).to start_with("sha256:")
      expect(info.id).to start_with("snap_")
      expect(info.scope).to eq(:disk)
      expect(info.state_kind).to eq("file")
      listed = Microsandbox::Snapshot.list.find { |h| h.id == info.id }
      expect(listed&.name).to eq(snap)
      expect(listed.digest).to eq(info.digest)

      # v0.7 snapshot groups: the artifact is a member of the group named after
      # the source sandbox, aliased `snap`, and that group's head. A bare name
      # selects a group head, so `snap` alone is not a selector any more.
      expect { Microsandbox::Snapshot.verify(snap) }.to raise_error(Microsandbox::SnapshotNotFoundError)
      [info.id, info.digest, info.path, "#{src}:#{snap}", src].each do |selector|
        expect(Microsandbox::Snapshot.get(selector).id).to eq(info.id)
      end

      report = Microsandbox::Snapshot.verify(info.id)
      expect(report).to be_a(Microsandbox::SnapshotVerifyReport)
      expect(report).to be_verified
      expect(report.algorithm).not_to be_nil

      # Archive round-trip via the renamed save/load: save the artifact,
      # remove the original, load it back, and confirm the same identity.
      require "tmpdir"
      Dir.mktmpdir do |dir|
        archive = File.join(dir, "snap.tar.zst")
        Microsandbox::Snapshot.save(info.id, archive)
        expect(File.size(archive)).to be > 0

        Microsandbox::Snapshot.remove(info.id, force: true)
        expect(Microsandbox::Snapshot.list.map(&:id)).not_to include(info.id)
        loaded = Microsandbox::Snapshot.load(archive)
        # The id and digest survive the round-trip (mirrors upstream's own
        # round-trip tests); the copy lands in a fresh generated group with no
        # head selected, so it is addressed by id, not by a name.
        expect(loaded.digest).to eq(info.digest)
        expect(loaded.id).to eq(info.id)
        expect(Microsandbox::Snapshot.verify(loaded.id)).to be_verified
      end
    ensure
      # Remove by id: a name alone no longer selects a member. One copy exists
      # at a time (the original is removed before the load), so the id is
      # unambiguous here.
      [loaded, info].compact.map(&:id).uniq.each do |id|
        Microsandbox::Snapshot.remove(id, force: true)
      rescue Microsandbox::Error
        nil
      end
      begin
        Microsandbox::Sandbox.remove(src)
      rescue Microsandbox::Error
        nil
      end
    end
  end

  it "boots a new sandbox from a snapshot" do
    pending "runtime v0.7 removed create(from_snapshot:); Sandbox.restore is not bound yet"
    src = unique_sandbox_name("rb-snapsrc")
    snap = "rb-snap-#{Process.pid}-#{rand(100_000)}"
    info = nil
    begin
      Microsandbox::Sandbox.create(src, image: image).stop
      info = Microsandbox::Snapshot.create(snap, from_sandbox: src)
      Microsandbox::Sandbox.restore(info.id, name: unique_sandbox_name("rb-snapboot")) do |sb2|
        expect(sb2.exec("true").exit_code).to eq(0)
      end
    ensure
      begin
        Microsandbox::Snapshot.remove(info.id, force: true) if info
      rescue Microsandbox::Error
        nil
      end
      begin
        Microsandbox::Sandbox.remove(src)
      rescue Microsandbox::Error
        nil
      end
    end
  end

  # v0.6.9 breaking change: without record_integrity: true no content digest
  # is recorded, and verify reports :not_recorded instead of :verified.
  it "reports :not_recorded for a snapshot created without record_integrity" do
    src = unique_sandbox_name("rb-snapnorec")
    snap = "rb-snapnorec-#{Process.pid}-#{rand(100_000)}"
    info = nil
    begin
      sb = Microsandbox::Sandbox.create(src, image: image)
      sb.stop

      info = Microsandbox::Snapshot.create(snap, from_sandbox: src)
      report = Microsandbox::Snapshot.verify("#{src}:#{snap}")
      expect(report).not_to be_verified
      expect(report.status).to eq(:not_recorded)
      expect(report.algorithm).to be_nil
      expect(report.content_digest).to be_nil
    ensure
      begin
        Microsandbox::Snapshot.remove(info.id, force: true) if info
      rescue Microsandbox::Error
        nil
      end
      begin
        Microsandbox::Sandbox.remove(src)
      rescue Microsandbox::Error
        nil
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
