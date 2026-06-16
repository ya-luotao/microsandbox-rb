# frozen_string_literal: true

# Unit coverage for the streaming-exec / image / volume surface. The native
# layer is stubbed; real behaviour is exercised by the integration specs.
RSpec.describe "streaming exec, images, volumes" do
  describe Microsandbox::ExecEvent do
    it "parses each event variant and decodes text" do
      out = described_class.new("type" => "stdout", "data" => "hello".b)
      expect(out.type).to eq(:stdout)
      expect(out).to be_stdout
      expect(out.text).to eq("hello")
      expect(out.data.encoding).to eq(Encoding::ASCII_8BIT)

      started = described_class.new("type" => "started", "pid" => 42)
      expect(started).to be_started
      expect(started.pid).to eq(42)

      exited = described_class.new("type" => "exited", "code" => 3)
      expect(exited).to be_exited
      expect(exited.code).to eq(3)
    end
  end

  describe Microsandbox::ExitStatus do
    it "exposes exit_code and success?" do
      expect(described_class.new("exit_code" => 0, "success" => true)).to be_success
      expect(described_class.new("exit_code" => 1, "success" => false)).to be_failure
    end
  end

  describe Microsandbox::ExecHandle do
    let(:native) { instance_double(Microsandbox::Native::ExecHandle) }
    subject(:handle) { described_class.new(native) }

    it "is Enumerable and yields events until recv returns nil" do
      allow(native).to receive(:recv).and_return(
        { "type" => "started", "pid" => 1 },
        { "type" => "stdout", "data" => "hi".b },
        { "type" => "exited", "code" => 0 },
        nil
      )
      types = handle.map(&:type)
      expect(types).to eq(%i[started stdout exited])
    end

    it "returns an Enumerator without a block" do
      expect(handle.each).to be_a(Enumerator)
    end

    it "wraps wait/collect and forwards signal/kill/resize" do
      allow(native).to receive(:wait).and_return("exit_code" => 0, "success" => true)
      allow(native).to receive(:collect).and_return(
        "exit_code" => 0, "success" => true, "stdout" => "out".b, "stderr" => "".b
      )
      allow(native).to receive(:signal)
      allow(native).to receive(:kill)
      allow(native).to receive(:resize)

      expect(handle.wait).to be_success
      expect(handle.collect).to be_a(Microsandbox::ExecOutput)
      handle.signal(15)
      handle.kill
      handle.resize(24, 80)
      expect(native).to have_received(:signal).with(15)
      expect(native).to have_received(:resize).with(24, 80)
    end

    it "wraps stdin once" do
      sink = instance_double(Microsandbox::Native::ExecSink, write: nil, close: nil)
      allow(native).to receive(:take_stdin).and_return(sink, nil)
      first = handle.stdin
      expect(first).to be_a(Microsandbox::ExecStdin)
      expect(handle.stdin).to equal(first) # memoized; take_stdin not called again
      first.write("data")
      expect(sink).to have_received(:write).with("data")
    end
  end

  describe Microsandbox::Image do
    it "maps list/get/remove/prune through the native layer" do
      allow(Microsandbox::Native::Image).to receive(:list).and_return(
        [{ "reference" => "alpine", "layer_count" => 1 }]
      )
      allow(Microsandbox::Native::Image).to receive(:remove)
      allow(Microsandbox::Native::Image).to receive(:prune).and_return(
        "image_refs_removed" => 1, "manifests_removed" => 0, "layers_removed" => 2,
        "fsmeta_removed" => 0, "vmdk_removed" => 0, "bytes_reclaimed" => 1024
      )

      expect(Microsandbox::Image.list.map(&:reference)).to eq(["alpine"])
      Microsandbox::Image.remove("alpine", force: true)
      expect(Microsandbox::Native::Image).to have_received(:remove).with("alpine", true)
      report = Microsandbox::Image.prune
      expect(report.bytes_reclaimed).to eq(1024)
      expect(report.layers_removed).to eq(2)
    end

    it "keeps the default class inspect when called with no argument" do
      expect(Microsandbox::Image.inspect).to include("Microsandbox::Image")
    end
  end

  describe Microsandbox::Volume do
    before do
      allow(Microsandbox::Native::Volume).to receive(:create).and_return("name" => "v", "path" => "/p")
      allow(Microsandbox::Native::Volume).to receive(:remove)
    end

    it "normalizes create options" do
      info = Microsandbox::Volume.create("v", kind: :disk, size_mib: 256, quota_mib: 512, labels: { a: 1 })
      expect(Microsandbox::Native::Volume).to have_received(:create).with(
        "v", hash_including("kind" => "disk", "size_mib" => 256, "quota_mib" => 512, "labels" => { "a" => "1" })
      )
      expect(info).to be_a(Microsandbox::VolumeInfo)
      expect(info.name).to eq("v")
      expect(info.path).to eq("/p")
    end

    it "removes by name" do
      Microsandbox::Volume.remove("v")
      expect(Microsandbox::Native::Volume).to have_received(:remove).with("v")
    end
  end

  describe "Sandbox streaming + volume/snapshot option mapping" do
    let(:native) { instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil) }
    before { allow(Microsandbox::Native::Sandbox).to receive(:create).and_return(native) }

    it "normalizes volumes and from_snapshot into create options" do
      Microsandbox::Sandbox.create(
        "box",
        from_snapshot: "snap-1",
        volumes: { "/data" => "/host/data", "/cache" => { named: "cache-vol" } }
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "from_snapshot" => "snap-1",
          "volumes" => [["/data", "bind", "/host/data"], ["/cache", "named", "cache-vol"]]
        )
      )
    end

    it "raises on a malformed volume spec" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", volumes: { "/data" => { wrong: 1 } })
      end.to raise_error(ArgumentError, /:bind or :named/)
    end

    it "wraps exec_stream in an ExecHandle" do
      stream = instance_double(Microsandbox::Native::ExecHandle)
      allow(native).to receive(:exec_stream).and_return(stream)
      sb = Microsandbox::Sandbox.create("box", image: "x")
      handle = sb.exec_stream("ls", ["-l"], tty: true)
      expect(handle).to be_a(Microsandbox::ExecHandle)
      expect(native).to have_received(:exec_stream).with("ls", ["-l"], hash_including("tty" => true))
    end
  end
end
