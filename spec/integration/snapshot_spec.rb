# frozen_string_literal: true

require "fileutils"
require "tmpdir"

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

  # Sandbox.restore (0.18.0): the snapshot's disk boots as a new sandbox,
  # addressed every way a caller holds a snapshot. Upstream restores detached,
  # so the block form's stop is what ends each one.
  it "boots new sandboxes from a snapshot with Sandbox.restore" do
    src = unique_sandbox_name("rb-snapsrc")
    bsrc = unique_sandbox_name("rb-snapbind")
    snap = "rb-snap-#{Process.pid}-#{rand(100_000)}"
    marker = "restore-#{rand(1_000_000)}"
    infos = []
    children = []
    child = ->(tag) { unique_sandbox_name("rb-snapboot-#{tag}").tap { |n| children << n } }
    read_marker = ->(sb) { sb.shell("cat /root/marker.txt").stdout.strip }
    Dir.mktmpdir("msb-rb-restore-", File.realpath(Dir.tmpdir)) do |dir|
      sb = Microsandbox::Sandbox.create(src, image: image)
      sb.fs.write("/root/marker.txt", marker)
      sb.stop
      info = Microsandbox::Snapshot.create(snap, from_sandbox: src)
      infos << info
      expect(info.reference_kind).to eq("path")
      expect(info.reference).to eq(info.path)

      # A SnapshotInfo (from create and from the index), its id, the
      # `group:member` selector, the group head, and a relative path.
      [info, Microsandbox::Snapshot.get(info.id), info.id, "#{src}:#{snap}", src].each_with_index do |selector, i|
        name = child.call(i)
        Microsandbox::Sandbox.restore(selector, name: name) do |restored|
          expect(read_marker.call(restored)).to eq(marker)
        end
        expect(Microsandbox::Sandbox.get(name).status).to eq(:stopped)
      end
      Dir.chdir(File.dirname(info.path)) do
        Microsandbox::Sandbox.restore("./#{File.basename(info.path)}", name: child.call("rel")) do |restored|
          expect(read_marker.call(restored)).to eq(marker)
        end
      end
      # A bare create name selects a group head, not this member.
      expect { Microsandbox::Sandbox.restore(snap, name: child.call("bare")) }
        .to raise_error(Microsandbox::SnapshotNotFoundError)

      # Without a block the sandbox stays up (upstream restores detached)
      # until stopped; destination resources apply.
      restored = Microsandbox::Sandbox.restore(info, name: child.call("live"), cpus: 2)
      begin
        expect(restored.status).to eq(:running)
        expect(restored.owns_lifecycle?).to be(false)
        expect(restored.shell("nproc").stdout.strip).to eq("2")
      ensure
        restored.stop_and_wait
      end

      # A captured bind mount needs a destination binding, or an explicit
      # allow_missing_resources: true.
      bind = File.join(dir, "bind")
      FileUtils.mkdir_p(bind)
      b = Microsandbox::Sandbox.create(bsrc, image: image, volumes: {"/data" => bind})
      b.shell("echo bound > /data/x")
      b.stop
      binfo = Microsandbox::Snapshot.create(snap, from_sandbox: bsrc)
      infos << binfo
      expect { Microsandbox::Sandbox.restore(binfo, name: child.call("nobind")) }
        .to raise_error(Microsandbox::InvalidConfigError, %r{restore requires destination bindings for: mount /data})
      Microsandbox::Sandbox.restore(binfo, name: child.call("bind"), volumes: {"/data" => bind}) do |restored|
        expect(restored.shell("cat /data/x").stdout.strip).to eq("bound")
      end
      Microsandbox::Sandbox.restore(binfo, name: child.call("missing"), allow_missing_resources: true) do |restored|
        expect(restored.status).to eq(:running)
      end

      # Archive round-trip: a loaded artifact has no group head; its
      # SnapshotInfo restores by reference.
      archive = File.join(dir, "snap.tar.zst")
      Microsandbox::Snapshot.save(info.id, archive)
      Microsandbox::Snapshot.remove(info.id, force: true)
      loaded = Microsandbox::Snapshot.load(archive)
      infos << loaded
      Microsandbox::Sandbox.restore(loaded, name: child.call("loaded")) do |restored|
        expect(read_marker.call(restored)).to eq(marker)
      end
    end
  ensure
    children.each do |name|
      Microsandbox::Sandbox.get(name).stop
    rescue Microsandbox::Error
      nil
    ensure
      begin
        Microsandbox::Sandbox.remove(name)
      rescue Microsandbox::Error
        nil
      end
    end
    infos.compact.map(&:id).uniq.each do |id|
      Microsandbox::Snapshot.remove(id, force: true)
    rescue Microsandbox::Error
      nil
    end
    [src, bsrc].each do |name|
      Microsandbox::Sandbox.remove(name)
    rescue Microsandbox::Error
      nil
    end
  end

  it "refuses guest_flush: :required for a stopped source" do
    src = unique_sandbox_name("rb-snapflush")
    begin
      Microsandbox::Sandbox.create(src, image: image).stop
      expect { Microsandbox::Snapshot.create("flush", from_sandbox: src, guest_flush: :required) }
        .to raise_error(Microsandbox::InvalidConfigError, /guest flush/)
      info = Microsandbox::Snapshot.create("flush", from_sandbox: src, guest_flush: :skip)
      Microsandbox::Snapshot.remove(info.id, force: true)
    ensure
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
