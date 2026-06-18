# frozen_string_literal: true

# Real microVM integration coverage for streaming exec, images, and volumes.
# Opt-in via MICROSANDBOX_INTEGRATION=1.
RSpec.describe "streaming, images, volumes", :integration do
  let(:image) { default_test_image }

  describe "streaming exec" do
    it "streams stdout events and a terminal exit" do
      Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
        events = sb.exec_stream("sh", ["-c", "echo one; echo two"]).to_a
        expect(events.map(&:type)).to include(:stdout, :exited)
        text = events.select(&:stdout?).map(&:text).join
        expect(text).to include("one").and include("two")
        expect(events.find(&:exited?).code).to eq(0)
      end
    end

    it "collects a stream into an ExecOutput" do
      Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
        out = sb.exec_stream("echo", ["streamed"]).collect
        expect(out).to be_success
        expect(out.stdout).to include("streamed")
      end
    end

    it "feeds stdin through the handle" do
      Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
        # `stdin: :pipe` opens a writable sink. `cat` reads stdin until EOF, so
        # closing the sink is what lets it exit — without the pipe (or without
        # the close) `collect` would block forever waiting for the exit event.
        handle = sb.exec_stream("cat", [], stdin: :pipe)
        sink = handle.stdin
        expect(sink).not_to be_nil
        sink.write("from-stdin")
        sink.close
        out = handle.collect
        expect(out.stdout).to include("from-stdin")
      end
    end
  end

  describe Microsandbox::Image do
    it "lists and inspects a pulled image, then prunes" do
      Microsandbox::Sandbox.create(unique_sandbox_name, image: image) { |sb| sb.exec("true") }
      refs = Microsandbox::Image.list.map(&:reference)
      expect(refs).not_to be_empty
      detail = Microsandbox::Image.inspect(refs.first)
      expect(detail).to be_a(Microsandbox::ImageDetail)
      expect(detail.handle.reference).to eq(refs.first)
      expect(Microsandbox::Image.prune).to be_a(Microsandbox::ImagePruneReport)
    end
  end

  describe Microsandbox::Volume do
    it "creates, lists, and removes a named volume" do
      name = "rb-vol-#{Process.pid}-#{rand(100_000)}"
      info = Microsandbox::Volume.create(name)
      begin
        expect(info.name).to eq(name)
        expect(Microsandbox::Volume.list.map(&:name)).to include(name)
        expect(Microsandbox::Volume.get(name).name).to eq(name)
      ensure
        Microsandbox::Volume.remove(name)
      end
      expect(Microsandbox::Volume.list.map(&:name)).not_to include(name)
    end

    it "mounts a named volume into a sandbox and persists data across sandboxes" do
      vol = "rb-persist-#{Process.pid}-#{rand(100_000)}"
      Microsandbox::Volume.create(vol)
      begin
        Microsandbox::Sandbox.create(unique_sandbox_name, image: image,
          volumes: {"/data" => {named: vol}}) do |sb|
          sb.fs.write("/data/persisted.txt", "across-boots")
        end
        Microsandbox::Sandbox.create(unique_sandbox_name, image: image,
          volumes: {"/data" => {named: vol}}) do |sb|
          expect(sb.fs.read_text("/data/persisted.txt")).to eq("across-boots")
        end
      ensure
        Microsandbox::Volume.remove(vol)
      end
    end
  end
end
