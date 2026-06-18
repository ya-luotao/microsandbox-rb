# frozen_string_literal: true

# Unit coverage for the rootfs-patch factory and its normalization into
# Sandbox.create options. The native layer is stubbed; real application is
# exercised by the integration specs.
RSpec.describe Microsandbox::Patch do
  describe "factory methods" do
    it "builds a text patch with mode and replace" do
      p = described_class.text("/etc/app.conf", "k = v\n", mode: 0o644, replace: true)
      expect(p).to eq(
        "kind" => "text", "path" => "/etc/app.conf", "content" => "k = v\n",
        "replace" => true, "mode" => 0o644
      )
    end

    it "omits mode when not given and defaults replace to false" do
      p = described_class.text("/a", "b")
      expect(p).to eq("kind" => "text", "path" => "/a", "content" => "b", "replace" => false)
      expect(p).not_to have_key("mode")
    end

    it "builds a binary file patch preserving raw bytes" do
      bytes = "\x00\x01\x02".b
      p = described_class.file("/bin/blob", bytes)
      expect(p["kind"]).to eq("file")
      expect(p["content"]).to eq(bytes)
      expect(p["content"].encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "builds append/mkdir/remove/symlink/copy patches" do
      expect(described_class.append("/etc/profile", "\nexport X=1\n")).to eq(
        "kind" => "append", "path" => "/etc/profile", "content" => "\nexport X=1\n"
      )
      expect(described_class.mkdir("/opt/app", mode: 0o755)).to eq(
        "kind" => "mkdir", "path" => "/opt/app", "mode" => 0o755
      )
      expect(described_class.remove("/etc/motd")).to eq("kind" => "remove", "path" => "/etc/motd")
      expect(described_class.symlink("/a", "/b", replace: true)).to eq(
        "kind" => "symlink", "target" => "/a", "link" => "/b", "replace" => true
      )
      expect(described_class.copy_file("./c.pem", "/etc/c.pem")).to eq(
        "kind" => "copy_file", "src" => "./c.pem", "dst" => "/etc/c.pem", "replace" => false
      )
      expect(described_class.copy_dir("./scripts", "/opt/scripts", replace: true)).to eq(
        "kind" => "copy_dir", "src" => "./scripts", "dst" => "/opt/scripts", "replace" => true
      )
    end
  end

  describe "Sandbox.create normalization" do
    let(:native) { instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil) }

    before do
      allow(Microsandbox::Native::Sandbox).to receive(:create).and_return(native)
      allow(Microsandbox).to receive(:ensure_runtime!)
    end

    it "passes factory-built patches through as string-keyed hashes" do
      Microsandbox::Sandbox.create(
        "box", image: "alpine",
        patches: [
          Microsandbox::Patch.mkdir("/opt/app"),
          Microsandbox::Patch.text("/opt/app/c.txt", "hi", mode: 0o600)
        ]
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "patches" => [
            {"kind" => "mkdir", "path" => "/opt/app"},
            {"kind" => "text", "path" => "/opt/app/c.txt", "content" => "hi", "replace" => false, "mode" => 0o600}
          ]
        )
      )
    end

    it "stringifies keys of a hand-written symbol-keyed patch hash" do
      Microsandbox::Sandbox.create(
        "box", image: "alpine",
        patches: [{kind: "remove", path: "/etc/motd"}]
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("patches" => [{"kind" => "remove", "path" => "/etc/motd"}])
      )
    end

    it "rejects a non-Hash patch" do
      expect do
        Microsandbox::Sandbox.create("box", image: "alpine", patches: ["nope"])
      end.to raise_error(ArgumentError, /patch must be a Hash/)
    end

    it "omits patches when none are given" do
      Microsandbox::Sandbox.create("box", image: "alpine")
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", {"image" => "alpine"}
      )
    end
  end
end
