# frozen_string_literal: true

# Unit coverage for the interactive-attach option mapping. The native attach is
# host-TTY coupled and cannot run without a real terminal + booted microVM, so
# only the pure-Ruby forwarding is unit-tested; behavior is covered (TTY-gated)
# by the integration specs.
RSpec.describe "Sandbox#attach" do
  let(:native) { instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil) }
  subject(:sandbox) { Microsandbox::Sandbox.new(native) }

  describe "#attach" do
    it "forwards command, args, and normalized options, returning the exit code" do
      allow(native).to receive(:attach).and_return(0)
      code = sandbox.attach(
        "bash", ["-l"],
        cwd: "/app", user: "app", env: {FOO: 1},
        detach_keys: "ctrl-p,ctrl-q", rlimits: {nofile: [1024, 2048]}
      )
      expect(code).to eq(0)
      expect(native).to have_received(:attach).with(
        "bash", ["-l"],
        {
          "cwd" => "/app", "user" => "app", "env" => {"FOO" => "1"},
          "detach_keys" => "ctrl-p,ctrl-q", "rlimits" => [["nofile", 1024, 2048]]
        }
      )
    end

    it "passes empty options and no args by default" do
      allow(native).to receive(:attach).and_return(130)
      expect(sandbox.attach("top")).to eq(130)
      expect(native).to have_received(:attach).with("top", [], {})
    end
  end

  describe "#attach_shell" do
    it "forwards to the native attach_shell and returns the exit code" do
      allow(native).to receive(:attach_shell).and_return(0)
      expect(sandbox.attach_shell).to eq(0)
      expect(native).to have_received(:attach_shell)
    end
  end
end
