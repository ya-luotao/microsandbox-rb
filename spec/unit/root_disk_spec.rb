# frozen_string_literal: true

# Wire-shape coverage for the RootDisk factory (the values Sandbox.create's
# root_disk: consumes). Validation of kind/field combinations is covered in
# sandbox_spec's create tests.
RSpec.describe Microsandbox::RootDisk do
  it "builds a managed spec with an optional size" do
    expect(described_class.managed).to eq("kind" => "managed")
    expect(described_class.managed(8192)).to eq("kind" => "managed", "size_mib" => 8192)
  end

  it "builds a tmpfs spec with an optional size" do
    expect(described_class.tmpfs).to eq("kind" => "tmpfs")
    expect(described_class.tmpfs(2048)).to eq("kind" => "tmpfs", "size_mib" => 2048)
  end

  it "builds a disk spec with optional format/fstype" do
    expect(described_class.disk("./scratch.img")).to eq("kind" => "disk", "path" => "./scratch.img")
    expect(described_class.disk("./s.bin", format: :raw, fstype: "ext4")).to eq(
      "kind" => "disk", "path" => "./s.bin", "format" => "raw", "fstype" => "ext4"
    )
  end

  it "builds a flat spec with optional size/fstype/clone (v0.6.9)" do
    expect(described_class.flat).to eq("kind" => "flat")
    expect(described_class.flat(8192, fstype: "ext4", clone: :reflink)).to eq(
      "kind" => "flat", "size_mib" => 8192, "fstype" => "ext4", "clone" => "reflink"
    )
  end

  it "coerces a non-Integer size via Integer()" do
    expect { described_class.managed("not-a-size") }.to raise_error(ArgumentError)
  end
end
