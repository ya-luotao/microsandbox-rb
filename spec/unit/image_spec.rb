# frozen_string_literal: true

# Option-normalization coverage for the Image archive API added with runtime
# v0.6.7 (load/save). The native layer is stubbed; the real round-trip is
# exercised by spec/integration/root_disk_image_spec.rb.
RSpec.describe Microsandbox::Image do
  describe ".load" do
    it "normalizes a single tag to a tag list and wraps results in ImageInfo" do
      allow(Microsandbox::Native::Image).to receive(:load).and_return(
        [{"reference" => "app:dev", "layer_count" => 2}]
      )
      infos = described_class.load("/tmp/app.tar", tag: "app:dev")
      expect(Microsandbox::Native::Image).to have_received(:load)
        .with("/tmp/app.tar", ["app:dev"])
      expect(infos).to all(be_a(Microsandbox::ImageInfo))
      expect(infos.first.reference).to eq("app:dev")
    end

    it "passes no tags when tag: is omitted" do
      allow(Microsandbox::Native::Image).to receive(:load).and_return([])
      described_class.load("/tmp/app.tar")
      expect(Microsandbox::Native::Image).to have_received(:load).with("/tmp/app.tar", [])
    end

    it "spools $stdin to a temp file when input_path is '-'" do
      require "stringio"
      captured_path = nil
      captured_bytes = nil
      allow(Microsandbox::Native::Image).to receive(:load) do |path, _tags|
        captured_path = path
        captured_bytes = File.binread(path)
        []
      end
      begin
        original_stdin = $stdin
        $stdin = StringIO.new("tar-bytes")
        described_class.load("-")
      ensure
        $stdin = original_stdin
      end
      expect(captured_path).not_to eq("-")
      expect(captured_bytes).to eq("tar-bytes")
      # The spool file is cleaned up after the call.
      expect(File.exist?(captured_path)).to be(false)
    end
  end

  describe ".save" do
    it "normalizes references and the format" do
      allow(Microsandbox::Native::Image).to receive(:save)
      described_class.save(["a:1", "b:2"], output_path: "/tmp/out.tar", format: :oci)
      expect(Microsandbox::Native::Image).to have_received(:save)
        .with(["a:1", "b:2"], "/tmp/out.tar", "oci")
    end

    it "defaults to the docker format and accepts a single reference" do
      allow(Microsandbox::Native::Image).to receive(:save)
      described_class.save("alpine:latest", output_path: "/tmp/out.tar")
      expect(Microsandbox::Native::Image).to have_received(:save)
        .with(["alpine:latest"], "/tmp/out.tar", "docker")
    end

    it "rejects an empty reference list before hitting the native layer" do
      allow(Microsandbox::Native::Image).to receive(:save)
      expect { described_class.save([], output_path: "/tmp/out.tar") }
        .to raise_error(ArgumentError, /at least one image reference/)
      expect(Microsandbox::Native::Image).not_to have_received(:save)
    end
  end
end
