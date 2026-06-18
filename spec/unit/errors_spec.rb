# frozen_string_literal: true

RSpec.describe "Microsandbox error hierarchy" do
  it "roots every error at Microsandbox::Error < StandardError" do
    expect(Microsandbox::Error.ancestors).to include(StandardError)
  end

  # Mirrors sdk/python/microsandbox/errors.py. A local (not a constant) so it can
  # drive example-group generation below without leaking a constant from the block.
  expected_codes = {
    "Error" => "microsandbox-error",
    "InvalidConfigError" => "invalid-config",
    "SandboxNotFoundError" => "sandbox-not-found",
    "SandboxNotRunningError" => "sandbox-not-running",
    "SandboxAlreadyExistsError" => "sandbox-already-exists",
    "SandboxStillRunningError" => "sandbox-still-running",
    "ExecTimeoutError" => "exec-timeout",
    "ExecFailedError" => "exec-failed",
    "FilesystemError" => "filesystem-error",
    "PathNotFoundError" => "path-not-found",
    "VolumeNotFoundError" => "volume-not-found",
    "VolumeAlreadyExistsError" => "volume-already-exists",
    "ImageNotFoundError" => "image-not-found",
    "ImageInUseError" => "image-in-use",
    "ImagePullFailedError" => "image-pull-failed",
    "NetworkPolicyError" => "network-policy-error",
    "SecretViolationError" => "secret-violation",
    "TlsError" => "tls-error",
    "IoError" => "io-error",
    "MetricsDisabledError" => "metrics-disabled",
    "MetricsUnavailableError" => "metrics-unavailable",
    "UnsupportedOperationError" => "unsupported-operation"
  }

  expected_codes.each do |name, code|
    describe "Microsandbox::#{name}" do
      let(:klass) { Microsandbox.const_get(name) }

      it "is defined" do
        expect(klass).to be_a(Class)
      end

      it "descends from Microsandbox::Error" do
        expect(klass.ancestors).to include(Microsandbox::Error)
      end

      it "exposes code #{code.inspect} at class and instance level" do
        expect(klass.code).to eq(code)
        expect(klass.new("boom").code).to eq(code)
      end
    end
  end

  it "defines exactly the expected error classes" do
    defined = Microsandbox.constants.grep(/Error\z/).map(&:to_s).sort
    expect(defined).to match_array(expected_codes.keys.sort)
  end

  it "carries the message like a normal exception" do
    err = Microsandbox::SandboxNotFoundError.new("no such sandbox")
    expect(err.message).to eq("no such sandbox")
    expect(err).to be_a(StandardError)
  end
end
