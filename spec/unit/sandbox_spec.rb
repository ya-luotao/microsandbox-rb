# frozen_string_literal: true

# These specs exercise the pure-Ruby option normalization in Microsandbox::Sandbox
# WITHOUT booting a real microVM, by stubbing the native layer. The native
# binding itself is covered by the integration specs.
RSpec.describe Microsandbox::Sandbox do
  let(:native) { instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil) }

  before do
    allow(Microsandbox::Native::Sandbox).to receive(:create).and_return(native)
  end

  describe ".create option mapping" do
    it "normalizes keyword args into a string-keyed options hash" do
      Microsandbox::Sandbox.create(
        "box",
        image: "python", cpus: 2, memory: 1024,
        env: { FOO: 1, "BAR" => :baz }, workdir: "/app",
        labels: { team: "core" }, ports: { "8080" => 80 },
        network: :public_only, entrypoint: %w[/bin/sh -c]
      )

      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "image" => "python",
          "cpus" => 2,
          "memory" => 1024,
          "workdir" => "/app",
          "env" => { "FOO" => "1", "BAR" => "baz" },
          "labels" => { "team" => "core" },
          "ports" => { 8080 => 80 },
          "network" => "public_only",
          "entrypoint" => ["/bin/sh", "-c"]
        )
      )
    end

    it "omits unspecified options" do
      Microsandbox::Sandbox.create("box", image: "alpine")
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", { "image" => "alpine" }
      )
    end

    it "prefers replace_with_timeout over replace" do
      Microsandbox::Sandbox.create("box", image: "x", replace: true, replace_with_timeout: 5)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("replace_with_timeout" => 5.0)
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_excluding("replace")
      )
    end

    it "returns a Sandbox when no block is given" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      expect(sb).to be_a(Microsandbox::Sandbox)
      expect(sb.name).to eq("box")
    end

    it "yields the sandbox and stops it (block form), returning the block value" do
      result = Microsandbox::Sandbox.create("box", image: "x") do |sb|
        expect(sb).to be_a(Microsandbox::Sandbox)
        :done
      end
      expect(result).to eq(:done)
      expect(native).to have_received(:stop)
    end

    it "stops the sandbox even if the block raises" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x") { raise "boom" }
      end.to raise_error("boom")
      expect(native).to have_received(:stop)
    end
  end

  describe "#exec option mapping" do
    let(:exec_result) do
      { "exit_code" => 0, "success" => true, "stdout" => "".b, "stderr" => "".b }
    end

    before { allow(native).to receive(:exec).and_return(exec_result) }

    it "passes command, args, and a normalized options hash" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      out = sb.exec("ls", ["-l", :foo], cwd: "/tmp", env: { A: 1 }, timeout: 5, tty: true, stdin: "in")

      expect(native).to have_received(:exec).with(
        "ls", ["-l", "foo"],
        hash_including("cwd" => "/tmp", "env" => { "A" => "1" }, "timeout" => 5.0, "tty" => true, "stdin" => "in")
      )
      expect(out).to be_a(Microsandbox::ExecOutput)
    end

    it "defaults args to an empty array" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      sb.exec("whoami")
      expect(native).to have_received(:exec).with("whoami", [], {})
    end
  end

  describe "#shell option mapping" do
    before do
      allow(native).to receive(:shell).and_return(
        { "exit_code" => 0, "success" => true, "stdout" => "".b, "stderr" => "".b }
      )
    end

    it "passes the script and normalized options" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      sb.shell("echo hi", timeout: 2)
      expect(native).to have_received(:shell).with("echo hi", hash_including("timeout" => 2.0))
    end
  end

  describe "#stop / #kill" do
    it "forwards optional float timeouts" do
      allow(native).to receive(:kill)
      sb = Microsandbox::Sandbox.create("box", image: "x")
      sb.stop(timeout: 3)
      sb.kill
      expect(native).to have_received(:stop).with(3.0)
      expect(native).to have_received(:kill).with(nil)
    end
  end
end
