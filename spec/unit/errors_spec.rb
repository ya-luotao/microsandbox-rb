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
    "SnapshotNotFoundError" => "snapshot-not-found",
    "SnapshotAlreadyExistsError" => "snapshot-already-exists",
    "SnapshotSandboxRunningError" => "snapshot-sandbox-running",
    "SnapshotImageMissingError" => "snapshot-image-missing",
    "SnapshotIntegrityError" => "snapshot-integrity",
    "NetworkPolicyError" => "network-policy-error",
    "SecretViolationError" => "secret-violation",
    "TlsError" => "tls-error",
    "IoError" => "io-error",
    "MetricsDisabledError" => "metrics-disabled",
    "MetricsUnavailableError" => "metrics-unavailable",
    "UnsupportedOperationError" => "unsupported-operation",
    "CloudHttpError" => "cloud-http",
    "UnsupportedError" => "unsupported"
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

  # Exercises the REAL native error mapping (not just the Ruby class table):
  # opening a snapshot at a path that cannot exist routes the core's
  # SnapshotNotFound variant through ext/microsandbox/src/error.rs::class_name to
  # the typed SnapshotNotFoundError. Disk-only, no microVM/runtime — deterministic
  # in CI. Guards against the variant silently falling back to the base Error.
  #
  # Pin the local backend explicitly: snapshot ops require it, and on a non-local
  # process-wide backend the open would raise UnsupportedError instead, masking
  # the mapping under test.
  it "maps a core Snapshot* variant to its typed class via the native layer" do
    Microsandbox.with_backend(:local) do
      expect do
        Microsandbox::Snapshot.open("/nonexistent/microsandbox-rb-spec/snap-xyz.msbsnap")
      end.to raise_error(Microsandbox::SnapshotNotFoundError) { |e|
        expect(e.code).to eq("snapshot-not-found")
      }
    end
  end
end
