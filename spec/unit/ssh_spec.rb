# frozen_string_literal: true

# Unit coverage for the SSH pure-Ruby layer (output value object, client/sftp/
# server wrappers, ssh-ops option mapping). The native transport is stubbed; the
# real SSH round-trip is exercised by the integration specs.
RSpec.describe "ssh" do
  describe Microsandbox::SshOutput do
    it "exposes status/success and decodes text and bytes" do
      out = described_class.new("status" => 0, "success" => true, "stdout" => "hi".b, "stderr" => "".b)
      expect(out.status).to eq(0)
      expect(out).to be_success
      expect(out).not_to be_failure
      expect(out.stdout).to eq("hi")
      expect(out.stdout.encoding).to eq(Encoding::UTF_8)
      expect(out.stdout_bytes.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "reports failure on a non-zero status" do
      out = described_class.new("status" => 2, "success" => false, "stdout" => "".b, "stderr" => "boom".b)
      expect(out).to be_failure
      expect(out.stderr).to eq("boom")
    end
  end

  describe Microsandbox::SftpClient do
    let(:native) { instance_double(Microsandbox::Native::SftpClient) }
    subject(:sftp) { described_class.new(native) }

    it "reads bytes and decodes text" do
      allow(native).to receive(:read).and_return("data".b)
      expect(sftp.read("/f")).to eq("data")
      expect(sftp.read_text("/f").encoding).to eq(Encoding::UTF_8)
      expect(native).to have_received(:read).with("/f").twice
    end

    it "delegates the mutating ops and returns nil" do
      %i[write mkdir remove_file remove_dir rename symlink close].each { |m| allow(native).to receive(m) }
      expect(sftp.write("/f", "x")).to be_nil
      expect(sftp.mkdir("/d")).to be_nil
      expect(sftp.rename("/a", "/b")).to be_nil
      expect(sftp.symlink("/t", "/l")).to be_nil
      expect(sftp.close).to be_nil
      expect(native).to have_received(:write).with("/f", "x")
      expect(native).to have_received(:rename).with("/a", "/b")
      expect(native).to have_received(:symlink).with("/t", "/l")
    end

    it "returns path strings from real_path/read_link" do
      allow(native).to receive(:real_path).and_return("/abs")
      allow(native).to receive(:read_link).and_return("/target")
      expect(sftp.real_path("rel")).to eq("/abs")
      expect(sftp.read_link("/l")).to eq("/target")
    end
  end

  describe Microsandbox::SshClient do
    let(:native) { instance_double(Microsandbox::Native::SshClient) }
    subject(:client) { described_class.new(native) }

    it "wraps exec in an SshOutput and passes the tty flag" do
      allow(native).to receive(:exec).and_return(
        "status" => 0, "success" => true, "stdout" => "ok".b, "stderr" => "".b
      )
      out = client.exec("uname", tty: true)
      expect(out).to be_a(Microsandbox::SshOutput)
      expect(out.stdout).to eq("ok")
      expect(native).to have_received(:exec).with("uname", true)
    end

    it "forwards attach with term/detach_keys" do
      allow(native).to receive(:attach).and_return(0)
      expect(client.attach(term: "xterm", detach_keys: "ctrl-p,ctrl-q")).to eq(0)
      expect(native).to have_received(:attach).with("xterm", "ctrl-p,ctrl-q")
    end

    it "opens an sftp session and auto-closes it in block form" do
      sftp_native = instance_double(Microsandbox::Native::SftpClient, close: nil)
      allow(native).to receive(:sftp).and_return(sftp_native)
      captured = nil
      client.sftp { |s| captured = s }
      expect(captured).to be_a(Microsandbox::SftpClient)
      expect(sftp_native).to have_received(:close)
    end
  end

  describe Microsandbox::SshOps do
    let(:native) { instance_double(Microsandbox::Native::Sandbox) }
    subject(:ops) { described_class.new(native) }

    it "maps open_client options with defaults" do
      client_native = instance_double(Microsandbox::Native::SshClient)
      allow(native).to receive(:ssh_open_client).and_return(client_native)
      ops.open_client
      expect(native).to have_received(:ssh_open_client).with("user" => "root", "sftp" => true)
    end

    it "includes term and a custom user/sftp flag" do
      client_native = instance_double(Microsandbox::Native::SshClient)
      allow(native).to receive(:ssh_open_client).and_return(client_native)
      ops.open_client(user: "app", term: "xterm", sftp: false)
      expect(native).to have_received(:ssh_open_client).with(
        "user" => "app", "sftp" => false, "term" => "xterm"
      )
    end

    it "auto-closes the client in block form" do
      client_native = instance_double(Microsandbox::Native::SshClient, close: nil)
      allow(native).to receive(:ssh_open_client).and_return(client_native)
      ops.open_client { |c| expect(c).to be_a(Microsandbox::SshClient) }
      expect(client_native).to have_received(:close)
    end

    it "maps prepare_server options" do
      server_native = instance_double(Microsandbox::Native::SshServer)
      allow(native).to receive(:ssh_prepare_server).and_return(server_native)
      ops.prepare_server(host_key_path: "/k", user: "app")
      expect(native).to have_received(:ssh_prepare_server).with(
        "sftp" => true, "host_key_path" => "/k", "user" => "app"
      )
    end
  end

  describe "Sandbox#ssh" do
    it "returns an SshOps bound to the native sandbox" do
      native = instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil)
      allow(Microsandbox::Native::Sandbox).to receive(:create).and_return(native)
      allow(Microsandbox).to receive(:ensure_runtime!)
      sb = Microsandbox::Sandbox.create("box", image: "x")
      expect(sb.ssh).to be_a(Microsandbox::SshOps)
    end
  end
end
