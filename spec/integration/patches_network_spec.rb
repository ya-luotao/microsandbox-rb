# frozen_string_literal: true

# Real-microVM integration coverage for rootfs patches and custom network
# policies. Opt-in via MICROSANDBOX_INTEGRATION=1. Mirrors the official Python
# (test_patches.py) and Go (examples/patches, examples/network) coverage.
RSpec.describe "patches and network", :integration do
  let(:image) { default_test_image }

  describe "rootfs patches" do
    it "applies mkdir/text/append/symlink before boot" do
      Microsandbox::Sandbox.create(
        unique_sandbox_name, image: image,
        patches: [
          Microsandbox::Patch.mkdir("/opt/app"),
          Microsandbox::Patch.text("/opt/app/config.txt", "base\n"),
          Microsandbox::Patch.append("/opt/app/config.txt", "appended\n"),
          Microsandbox::Patch.symlink("/opt/app/config.txt", "/opt/app/link.txt")
        ]
      ) do |sb|
        out = sb.shell("test -d /opt/app && cat /opt/app/config.txt && cat /opt/app/link.txt")
        expect(out).to be_success
        expect(out.stdout).to eq("base\nappended\nbase\nappended\n")
      end
    end

    it "copies a host file in and removes an existing rootfs file" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        host_file = File.join(dir, "staged.toml")
        File.write(host_file, "staged = true\n")
        Microsandbox::Sandbox.create(
          unique_sandbox_name, image: image,
          patches: [
            Microsandbox::Patch.copy_file(host_file, "/etc/staged.toml", mode: 0o644),
            Microsandbox::Patch.remove("/etc/motd")
          ]
        ) do |sb|
          expect(sb.fs.read_text("/etc/staged.toml")).to eq("staged = true\n")
          gone = sb.shell("test -e /etc/motd && echo present || echo gone")
          expect(gone.stdout).to include("gone")
        end
      end
    end

    # The binary `file` patch is the only variant with a distinct native byte
    # path (RString::as_slice copy) and no Python analogue, so the end-to-end
    # round-trip — NUL-containing bytes through the guest filesystem — is only
    # exercised here. (The pure-Ruby factory bytes are asserted in patch_spec.rb.)
    it "writes a binary file patch with NUL bytes, byte-exact" do
      blob = "\x00\xff\x01\x02\x00\x80".b
      Microsandbox::Sandbox.create(
        unique_sandbox_name, image: image,
        patches: [Microsandbox::Patch.file("/opt/blob.bin", blob, mode: 0o600)]
      ) do |sb|
        got = sb.fs.read("/opt/blob.bin")
        expect(got.b).to eq(blob)
        # Cross-check the byte count via a shell probe (guards against truncation).
        size = sb.shell("wc -c < /opt/blob.bin").stdout.strip
        expect(size).to eq(blob.bytesize.to_s)
      end
    end
  end

  describe "custom network policy" do
    it "allows only an explicitly permitted egress destination" do
      policy = Microsandbox::NetworkPolicy.custom(
        default_egress: :deny,
        default_ingress: :allow,
        rules: [Microsandbox::Rule.allow(destination: "1.1.1.1", protocol: :tcp, port: "443")]
      )
      Microsandbox::Sandbox.create(unique_sandbox_name, image: image, network: policy) do |sb|
        probe = sb.shell(
          "nc -z -w 5 1.1.1.1 443 >/dev/null 2>&1 && echo allowed-OK || echo allowed-FAIL; " \
          "nc -z -w 5 8.8.8.8 443 >/dev/null 2>&1 && echo other-OK || echo other-FAIL",
          timeout: 25
        )
        expect(probe.stdout).to include("allowed-OK")
        expect(probe.stdout).to include("other-FAIL")
      end
    end

    it "blocks all egress with the none preset" do
      Microsandbox::Sandbox.create(unique_sandbox_name, image: image, network: :none) do |sb|
        probe = sb.shell(
          "nc -z -w 3 1.1.1.1 443 >/dev/null 2>&1 && echo public-OK || echo public-FAIL",
          timeout: 15
        )
        expect(probe.stdout).to include("public-FAIL")
      end
    end

    it "accepts a preset base plus a bulk domain denial" do
      Microsandbox::Sandbox.create(
        unique_sandbox_name, image: image,
        network: {preset: :public_only, deny_domains: ["example.com"]}
      ) do |sb|
        # The sandbox still boots and runs; the deny rule is enforced by the proxy.
        expect(sb.shell("echo ok").stdout).to include("ok")
      end
    end
  end
end
