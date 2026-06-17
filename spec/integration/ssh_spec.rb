# frozen_string_literal: true

# Real-microVM integration coverage for SSH. Opt-in via MICROSANDBOX_INTEGRATION=1.
# Mirrors the official Python (test_ssh) and Go (ssh.go) coverage.
RSpec.describe "ssh", :integration do
  let(:image) { default_test_image }

  it "runs a command over a native in-process SSH client" do
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
      sb.ssh.open_client do |client|
        out = client.exec("echo hello-ssh")
        expect(out).to be_success
        expect(out.stdout).to include("hello-ssh")
      end
    end
  end

  it "surfaces a non-zero exit status" do
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
      sb.ssh.open_client do |client|
        out = client.exec("exit 3")
        expect(out).to be_failure
        expect(out.status).to eq(3)
      end
    end
  end

  it "round-trips a file and directory tree over SFTP" do
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
      sb.ssh.open_client do |client|
        client.sftp do |sftp|
          sftp.mkdir("/tmp/sftpdir")
          sftp.write("/tmp/sftpdir/a.txt", "via-sftp")
          expect(sftp.read_text("/tmp/sftpdir/a.txt")).to eq("via-sftp")
          sftp.rename("/tmp/sftpdir/a.txt", "/tmp/sftpdir/b.txt")
          expect(sftp.read_text("/tmp/sftpdir/b.txt")).to eq("via-sftp")
          sftp.remove_file("/tmp/sftpdir/b.txt")
          sftp.remove_dir("/tmp/sftpdir")
        end
      end
    end
  end
end
