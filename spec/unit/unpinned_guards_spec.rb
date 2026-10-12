# frozen_string_literal: true

# Behaviour that no other spec pinned: each example fails if the guard it
# names is removed or inverted. Stub-level, like sandbox_spec.rb.
RSpec.describe "guards no other spec pins" do
  let(:native) { instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil) }

  before do
    allow(Microsandbox::Native::Sandbox).to receive(:create).and_return(native)
    allow(Microsandbox::Native::Sandbox).to receive(:connect_or_create).and_return(native)
    allow(Microsandbox).to receive(:ensure_runtime!)
  end

  describe "secret-safe error messages" do
    it "never echoes a registry password in the half-specified registry_auth error" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", registry_auth: {password: "hunter2-registry"})
      end.to raise_error(ArgumentError) { |e| expect(e.message).not_to include("hunter2-registry") }
    end
  end

  describe "exec stdin modes" do
    before { allow(native).to receive(:exec) }

    it "rejects an unknown stdin Symbol with ArgumentError instead of feeding its name as bytes" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      expect { sb.exec("cat", stdin: :inherit) }.to raise_error(ArgumentError, /unknown stdin mode :inherit/)
      expect(native).not_to have_received(:exec)
    end

    it "rejects a non-String stdin with TypeError instead of stringifying it" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      expect { sb.exec("cat", stdin: 42) }.to raise_error(TypeError, /stdin must be/)
      expect(native).not_to have_received(:exec)
    end
  end

  describe "runtime provisioning call sites" do
    it "provisions the runtime before Sandbox.start" do
      allow(Microsandbox::Native::Sandbox).to receive(:start).and_return(native)
      Microsandbox::Sandbox.start("box")
      expect(Microsandbox).to have_received(:ensure_runtime!)
    end
  end

  describe "block-form teardown" do
    it "swallows a stop failure after the .create block and still returns the block value" do
      allow(native).to receive(:stop).and_raise(Microsandbox::SandboxNotRunningError, "gone")
      expect(Microsandbox::Sandbox.create("box", image: "x") { :value }).to eq(:value)
    end

    it "lets the block's own exception win over a stop failure after .create" do
      allow(native).to receive(:stop).and_raise(Microsandbox::SandboxNotRunningError, "gone")
      expect { Microsandbox::Sandbox.create("box", image: "x") { raise IOError, "from block" } }
        .to raise_error(IOError, "from block")
    end

    it "stops an owned sandbox even when the .connect_or_create block raises" do
      allow(native).to receive(:owns_lifecycle).and_return(true)
      expect { Microsandbox::Sandbox.connect_or_create("box", image: "x") { raise "boom" } }
        .to raise_error("boom")
      expect(native).to have_received(:stop)
    end

    it "closes the write sink when the fs.write_stream block raises" do
      sink = instance_double(Microsandbox::Native::FsWriteSink, close: nil)
      allow(native).to receive(:fs_write_stream).and_return(sink)
      sb = Microsandbox::Sandbox.create("box", image: "x")
      expect { sb.fs.write_stream("/f") { raise "boom" } }.to raise_error("boom")
      expect(sink).to have_received(:close)
    end

    it "closes the SSH client when the open_client block raises" do
      client = instance_double(Microsandbox::Native::SshClient, close: nil)
      allow(native).to receive(:ssh_open_client).and_return(client)
      sb = Microsandbox::Sandbox.create("box", image: "x")
      expect { sb.ssh.open_client { raise "boom" } }.to raise_error("boom")
      expect(client).to have_received(:close)
    end

    it "closes the SFTP session when the sftp block raises" do
      sftp = instance_double(Microsandbox::Native::SftpClient, close: nil)
      client = instance_double(Microsandbox::Native::SshClient, close: nil, sftp: sftp)
      expect { Microsandbox::SshClient.new(client).sftp { raise "boom" } }.to raise_error("boom")
      expect(sftp).to have_received(:close)
    end

    it "closes the agent client when the connect block raises" do
      agent = instance_double(Microsandbox::Native::AgentClient, close: nil)
      allow(Microsandbox::Native::AgentClient).to receive(:connect_sandbox).and_return(agent)
      expect { Microsandbox::AgentClient.connect_sandbox("box") { raise "boom" } }.to raise_error("boom")
      expect(agent).to have_received(:close)
    end
  end

  describe "logs / snapshot option mapping" do
    it "forwards tail: and sources: to native logs" do
      allow(native).to receive(:logs).and_return([])
      Microsandbox::Sandbox.create("box", image: "x").logs(tail: 5, sources: %i[stdout system])
      expect(native).to have_received(:logs).with("tail" => 5, "sources" => %w[stdout system])
    end

    it "forwards plain_tar: to native snapshot save" do
      allow(Microsandbox::Native::Snapshot).to receive(:save)
      Microsandbox::Snapshot.save("snap", "/out.tar", plain_tar: true)
      expect(Microsandbox::Native::Snapshot).to have_received(:save).with("snap", "/out.tar", {"plain_tar" => true})
    end
  end

  describe "network rule validation" do
    it "rejects a non-Hash rule with an actionable ArgumentError" do
      expect { Microsandbox::NetworkPolicy.custom(rules: ["allow 1.1.1.1"]) }
        .to raise_error(ArgumentError, /rule must be a Hash/)
    end
  end

  describe "Microsandbox.setup option mapping" do
    before { allow(Microsandbox::Native).to receive(:setup) }

    it "forwards base_dir/version/force/skip_verify" do
      Microsandbox.setup(base_dir: "/opt/msb", version: "0.6.18", force: true, skip_verify: true)
      expect(Microsandbox::Native).to have_received(:setup).with(
        "base_dir" => "/opt/msb", "version" => "0.6.18", "force" => true, "skip_verify" => true
      )
    end

    it "sends an empty Hash by default (no accidental force/skip)" do
      Microsandbox.setup
      expect(Microsandbox::Native).to have_received(:setup).with({})
    end
  end

  describe "MICROSANDBOX_NO_AUTO_INSTALL parsing" do
    around do |example|
      Microsandbox.instance_variable_set(:@runtime_ready, nil)
      example.run
      Microsandbox.instance_variable_set(:@runtime_ready, nil)
    end

    before do
      allow(Microsandbox).to receive(:ensure_runtime!).and_call_original
      allow(Microsandbox).to receive(:installed?).and_return(true)
      allow(Microsandbox).to receive(:install)
    end

    def ensure_runtime_with(value)
      stub_const("ENV", ENV.to_h.merge("MICROSANDBOX_NO_AUTO_INSTALL" => value))
      Microsandbox.ensure_runtime!
    end

    ["0", "false", "FALSE", "no", "No", ""].each do |value|
      it "treats #{value.inspect} as NOT disabled (auto-install still runs)" do
        ensure_runtime_with(value)
        expect(Microsandbox).to have_received(:install).once
      end
    end

    %w[1 true yes on].each do |value|
      it "treats #{value.inspect} as disabled" do
        ensure_runtime_with(value)
        expect(Microsandbox).not_to have_received(:install)
      end
    end
  end

  describe "bundled-runtime owner attribution" do
    it "does not attribute a sibling directory sharing the gem path as a prefix" do
      mod = Module.new
      src = "/gems/microsandbox-rb-binaries-evil/lib/microsandbox/binaries.rb"
      mod.define_singleton_method(:msb_path) {}
      allow(mod).to receive(:method).with(:msb_path).and_return(double(source_location: [src, 1]))
      stub_const("Microsandbox::Binaries", mod)
      trusted = instance_double(Gem::Specification, name: "microsandbox-rb-binaries",
        full_gem_path: "/gems/microsandbox-rb-binaries")
      allow(Gem).to receive(:loaded_specs).and_return({"microsandbox-rb-binaries" => trusted})
      expect(Microsandbox.send(:bundled_runtime_owner)).to be_nil
    end
  end

  describe ".with_backend restore" do
    # Push a CLOUD backend over the local default: a `:local` over `:local`
    # swap cannot tell a missing pop from a working one.
    it "restores the previous backend when the block raises" do
      expect {
        Microsandbox.with_backend(:cloud, url: "http://127.0.0.1:9", api_key: "k") do
          expect(Microsandbox.default_backend_kind).to eq(:cloud)
          raise "boom"
        end
      }.to raise_error("boom")
      expect(Microsandbox.default_backend_kind).to eq(:local)
    end
  end
end
