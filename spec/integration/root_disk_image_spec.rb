# frozen_string_literal: true

require "tmpdir"

# Real microVM integration coverage for the v0.6.7 structured root disk and
# the Image.save/Image.load archive round-trip.
# Opt-in via MICROSANDBOX_INTEGRATION=1.
RSpec.describe "root disk + image archives", :integration do
  let(:image) { default_test_image }

  it "boots with a tmpfs root disk that is pristine after a restart" do
    name = unique_sandbox_name("rb-tmpfsroot")
    begin
      sb = Microsandbox::Sandbox.create(
        name, image: image, memory: 512,
        root_disk: Microsandbox::RootDisk.tmpfs(128)
      )
      sb.shell("echo scratch > /root/scratch.txt")
      expect(sb.fs.read_text("/root/scratch.txt")).to include("scratch")
      sb.stop

      # The RAM-backed upper is dropped on stop — a restart boots pristine.
      sb2 = Microsandbox::Sandbox.start(name)
      begin
        expect(sb2.fs.exists?("/root/scratch.txt")).to be(false)
      ensure
        sb2.stop
      end
    ensure
      begin
        Microsandbox::Sandbox.remove(name)
      rescue Microsandbox::Error
        # best-effort cleanup
      end
    end
  end

  it "caps the managed root disk via the Integer shorthand" do
    Microsandbox::Sandbox.create(unique_sandbox_name("rb-rootcap"), image: image, root_disk: 1024) do |sb|
      expect(sb.exec("true")).to be_success
    end
  end

  # v0.6.9: a flat root disk materializes the OCI image into one complete,
  # resizable ext4 disk (no overlay stack at runtime).
  it "boots from a flat root disk" do
    Microsandbox::Sandbox.create(
      unique_sandbox_name("rb-flatroot"), image: image, memory: 512,
      root_disk: Microsandbox::RootDisk.flat(2048)
    ) do |sb|
      out = sb.shell("echo flat-ok && df -h /")
      expect(out).to be_success
      expect(out.stdout).to include("flat-ok")
    end
  end

  # v0.6.9: per-sandbox egress/ingress rate limits. Boot-smoke — the sandbox
  # comes up and executes with limits applied (throughput assertions would be
  # flaky in CI; the limit plumbing itself is what this pins).
  it "boots with egress/ingress rate limits applied" do
    Microsandbox::Sandbox.create(
      unique_sandbox_name("rb-ratelimit"), image: image, memory: 512,
      rate_limiter: {
        egress: {bandwidth: {size: 10_485_760, refill_time_ms: 1000},
                 ops: {size: 10_000, refill_time_ms: 1000}},
        ingress: {bandwidth: {size: 10_485_760, refill_time_ms: 1000}}
      }
    ) do |sb|
      expect(sb.exec("true")).to be_success
    end
  end

  # v0.6.9: modify(root_disk_size:) grows the managed upper while stopped.
  it "plans a root-disk grow via modify(root_disk_size:)" do
    name = unique_sandbox_name("rb-rootgrow")
    begin
      sb = Microsandbox::Sandbox.create(name, image: image, root_disk: 1024)
      sb.stop

      handle = Microsandbox::Sandbox.get(name)
      plan = handle.modify(root_disk_size: 2048, policy: :next_start)
      expect(plan.changes.map { |c| c[:field] }).to include("root_disk_size")
    ensure
      begin
        Microsandbox::Sandbox.remove(name)
      rescue Microsandbox::Error
        # best-effort cleanup
      end
    end
  end

  it "round-trips an image through save and load" do
    tag = "rb-loaded-#{Process.pid}:test"
    Dir.mktmpdir do |dir|
      out = File.join(dir, "img.tar")
      Microsandbox::Image.save(image, output_path: out)
      expect(File.size(out)).to be > 0

      loaded = Microsandbox::Image.load(out, tag: tag)
      expect(loaded).to all(be_a(Microsandbox::ImageInfo))
      expect(Microsandbox::Image.list.map(&:reference)).to include(tag)
    ensure
      begin
        Microsandbox::Image.remove(tag, force: true)
      rescue Microsandbox::Error
        # best-effort cleanup
      end
    end
  end
end
