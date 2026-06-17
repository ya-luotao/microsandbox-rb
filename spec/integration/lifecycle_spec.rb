# frozen_string_literal: true

# Real microVM integration tests. Opt-in via MICROSANDBOX_INTEGRATION=1.
# These boot actual sandboxes from an OCI image (default: alpine; override with
# MICROSANDBOX_TEST_IMAGE), so they require a working runtime and network access
# for the first image pull.
RSpec.describe "Sandbox lifecycle", :integration do
  let(:image) { default_test_image }

  it "creates, execs, and stops via the block form" do
    captured = nil
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image, memory: 512, cpus: 1) do |sb|
      out = sb.exec("echo", ["hello from ruby"])
      captured = out
      expect(out.exit_code).to eq(0)
      expect(out).to be_success
      expect(out.stdout).to include("hello from ruby")
    end
    expect(captured).to be_a(Microsandbox::ExecOutput)
  end

  it "runs shell scripts with pipes" do
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
      out = sb.shell("printf 'abc' | wc -c")
      expect(out).to be_success
      expect(out.stdout.strip).to eq("3")
    end
  end

  it "reports a non-zero exit without raising" do
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
      out = sb.exec("sh", ["-c", "exit 7"])
      expect(out).to be_failure
      expect(out.exit_code).to eq(7)
    end
  end

  it "round-trips guest filesystem operations" do
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
      sb.fs.write("/tmp/hello.txt", "guest-data")
      expect(sb.fs.exists?("/tmp/hello.txt")).to be(true)
      expect(sb.fs.read_text("/tmp/hello.txt")).to eq("guest-data")
      expect(sb.fs.read("/tmp/hello.txt").encoding).to eq(Encoding::ASCII_8BIT)

      sb.fs.mkdir("/tmp/sub")
      sb.fs.copy("/tmp/hello.txt", "/tmp/sub/copy.txt")
      names = sb.fs.list("/tmp/sub").map(&:name)
      expect(names).to include("copy.txt")

      stat = sb.fs.stat("/tmp/hello.txt")
      expect(stat).to be_file
      expect(stat.size).to eq("guest-data".bytesize)
    end
  end

  it "passes environment variables and honors cwd" do
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
      out = sb.exec("sh", ["-c", "echo $GREETING"], env: { "GREETING" => "hi-env" })
      expect(out.stdout.strip).to eq("hi-env")

      out2 = sb.exec("pwd", [], cwd: "/tmp")
      expect(out2.stdout.strip).to eq("/tmp")
    end
  end

  it "feeds stdin" do
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
      out = sb.exec("cat", [], stdin: "piped-input")
      expect(out.stdout).to include("piped-input")
    end
  end

  it "lists sandboxes and removes by name" do
    name = unique_sandbox_name
    sb = Microsandbox::Sandbox.create(name, image: image)
    begin
      names = Microsandbox::Sandbox.list.map(&:name)
      expect(names).to include(name)
    ensure
      sb.stop
    end
    Microsandbox::Sandbox.remove(name)
    expect(Microsandbox::Sandbox.list.map(&:name)).not_to include(name)
  end

  it "raises a typed error for an invalid image reference" do
    expect do
      Microsandbox::Sandbox.create(unique_sandbox_name, image: "this/image::definitely-not-valid!!")
    end.to raise_error(Microsandbox::Error)
  end
end
