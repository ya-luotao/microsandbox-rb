# frozen_string_literal: true

# Unit coverage for the host-side VolumeFs pure-Ruby wrapper (delegation, value
# wrapping, write type-checking). The native VolumeFs is stubbed; the real
# host-filesystem round-trip is exercised by the integration specs.
RSpec.describe Microsandbox::VolumeFs do
  let(:native) { instance_double(Microsandbox::Native::VolumeFs) }
  subject(:fs) { described_class.new(native) }

  it "reads bytes and text" do
    allow(native).to receive(:read).with("/a").and_return("xx".b)
    allow(native).to receive(:read_text).with("/a").and_return("hi")
    expect(fs.read("/a")).to eq("xx")
    expect(fs.read_text("/a")).to eq("hi")
  end

  it "wraps list entries in FsEntry and stat in FsMetadata" do
    allow(native).to receive(:list).with("/d").and_return(
      [{"path" => "/d/f", "type" => "file", "size" => 1, "mode" => 0o644, "modified_ms" => nil}]
    )
    allow(native).to receive(:stat).with("/d").and_return(
      {"type" => "directory", "size" => 0, "mode" => 0o755,
       "readonly" => false, "modified_ms" => nil, "created_ms" => nil}
    )
    expect(fs.list("/d").first).to be_a(Microsandbox::FsEntry)
    expect(fs.stat("/d")).to be_a(Microsandbox::FsMetadata)
  end

  it "rejects non-String writes (no silent to_s)" do
    expect { fs.write("/a", 42) }.to raise_error(TypeError, /must be a String/)
  end

  it "delegates a String write (binary-safe)" do
    allow(native).to receive(:write)
    fs.write("/a", "data".b)
    expect(native).to have_received(:write).with("/a", "data")
  end

  it "returns exists? as a boolean and nil from the mutators" do
    allow(native).to receive(:exists).with("/a").and_return(true)
    allow(native).to receive(:mkdir)
    expect(fs.exists?("/a")).to be(true)
    expect(fs.mkdir("/a")).to be_nil
  end
end
