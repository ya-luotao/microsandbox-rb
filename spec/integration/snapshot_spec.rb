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

      info = Microsandbox::Snapshot.create(snap, from_sandbox: src)
      expect(info).to be_a(Microsandbox::SnapshotInfo)
      expect(info.digest).to start_with("sha256:")
      expect(info.scope).to eq(:disk)
      expect(info.state_kind).to eq("file")
      expect(Microsandbox::Snapshot.list.map(&:name)).to include(snap)

      report = Microsandbox::Snapshot.verify(snap)
      expect(report).to be_a(Microsandbox::SnapshotVerifyReport)
      expect(report).to be_verified

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
        expect(loaded.digest).to eq(info.digest)
        expect(Microsandbox::Snapshot.list.map(&:name)).to include(snap)
      end
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
    # The image is already cached by earlier specs; never must not hit a registry.
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image, pull_policy: "never") do |sb|
      expect(sb.exec("true")).to be_success
    end
  end
end
