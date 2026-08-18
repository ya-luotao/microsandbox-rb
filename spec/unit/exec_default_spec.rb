# frozen_string_literal: true

# Unit coverage for the default-workload execution surface (runtime v0.6.9):
# exec_default / exec_default_stream / attach_default run the image's resolved
# OCI ENTRYPOINT+CMD. Only the pure-Ruby option forwarding is unit-tested;
# behavior is covered by the integration specs.
RSpec.describe "Sandbox default-workload execution" do
  let(:native) { instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil) }
  subject(:sandbox) { Microsandbox::Sandbox.new(native) }

  let(:output_hash) do
    {"exit_code" => 0, "success" => true, "stdout" => "hi", "stderr" => ""}
  end

  describe "#exec_default" do
    it "forwards normalized exec options (no command) and wraps the output" do
      allow(native).to receive(:exec_default).and_return(output_hash)
      out = sandbox.exec_default(cwd: "/app", user: "app", env: {FOO: 1},
        timeout: 5, tty: true, stdin: "data")
      expect(out).to be_a(Microsandbox::ExecOutput)
      expect(out.exit_code).to eq(0)
      expect(native).to have_received(:exec_default).with(
        {
          "cwd" => "/app", "user" => "app", "env" => {"FOO" => "1"},
          "timeout" => 5.0, "tty" => true, "stdin" => "data"
        }
      )
    end

    it "passes empty options by default" do
      allow(native).to receive(:exec_default).and_return(output_hash)
      sandbox.exec_default
      expect(native).to have_received(:exec_default).with({})
    end

    it "rejects stdin: :pipe (blocking call has no writable sink)" do
      expect { sandbox.exec_default(stdin: :pipe) }.to raise_error(ArgumentError, /:pipe/)
    end
  end

  describe "#exec_default_stream" do
    it "forwards options and wraps the native handle in an ExecHandle" do
      native_handle = instance_double(Microsandbox::Native::ExecHandle)
      allow(native).to receive(:exec_default_stream).and_return(native_handle)
      handle = sandbox.exec_default_stream(cwd: "/srv", stdin: :pipe)
      expect(handle).to be_a(Microsandbox::ExecHandle)
      expect(native).to have_received(:exec_default_stream).with(
        {"cwd" => "/srv", "stdin_pipe" => true}
      )
    end
  end

  describe "#attach_default" do
    it "forwards normalized attach options and returns the exit code" do
      allow(native).to receive(:attach_default).and_return(0)
      code = sandbox.attach_default(
        cwd: "/app", user: "app", env: {FOO: 1},
        detach_keys: "ctrl-p,ctrl-q", rlimits: {nofile: [1024, 2048]}
      )
      expect(code).to eq(0)
      expect(native).to have_received(:attach_default).with(
        {
          "cwd" => "/app", "user" => "app", "env" => {"FOO" => "1"},
          "detach_keys" => "ctrl-p,ctrl-q", "rlimits" => [["nofile", 1024, 2048]]
        }
      )
    end

    it "passes empty options by default" do
      allow(native).to receive(:attach_default).and_return(130)
      expect(sandbox.attach_default).to eq(130)
      expect(native).to have_received(:attach_default).with({})
    end
  end
end
