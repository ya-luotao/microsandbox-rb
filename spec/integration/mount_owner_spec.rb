# frozen_string_literal: true

require "tmpdir"

# Real microVM coverage for the per-mount fallback owner (`uid:`/`gid:`,
# runtime v0.6.15 / upstream #1451). A file created on the host carries no
# per-file stat override, so without an owner pin the guest sees the runtime's
# fallback owner; with one it sees exactly the requested uid/gid.
# Opt-in via MICROSANDBOX_INTEGRATION=1.
RSpec.describe "bind-mount ownership", :integration do
  let(:image) { default_test_image }

  it "presents host files under the pinned uid:/gid: inside the guest" do
    Dir.mktmpdir("rb-mount-owner") do |tmp|
      # macOS puts tmpdirs under /var, itself a symlink to /private/var, and the
      # default-on mount-root symlink protection refuses to resolve through it.
      host_dir = File.realpath(tmp)
      File.write(File.join(host_dir, "host.txt"), "owned")

      Microsandbox::Sandbox.create(
        unique_sandbox_name, image: image,
        volumes: {"/data" => {bind: host_dir, uid: 4242, gid: 4343}}
      ) do |sb|
        out = sb.exec("stat", ["-c", "%u %g", "/data/host.txt"])
        expect(out).to be_success
        expect(out.stdout.strip).to eq("4242 4343")
      end
    end
  end

  it "still reports the runtime's fallback owner without uid:/gid:" do
    Dir.mktmpdir("rb-mount-owner") do |tmp|
      # macOS puts tmpdirs under /var, itself a symlink to /private/var, and the
      # default-on mount-root symlink protection refuses to resolve through it.
      host_dir = File.realpath(tmp)
      File.write(File.join(host_dir, "host.txt"), "unowned")

      Microsandbox::Sandbox.create(
        unique_sandbox_name, image: image,
        volumes: {"/data" => {bind: host_dir}}
      ) do |sb|
        out = sb.exec("stat", ["-c", "%u %g", "/data/host.txt"])
        expect(out).to be_success
        expect(out.stdout.strip).not_to eq("4242 4343")
      end
    end
  end
end
