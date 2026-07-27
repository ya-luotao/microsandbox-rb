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
