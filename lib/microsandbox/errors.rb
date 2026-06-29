# frozen_string_literal: true

module Microsandbox
  # Base class for every error raised by the SDK. Mirrors the Python SDK's
  # flat hierarchy (`sdk/python/microsandbox/errors.py`): each class carries a
  # stable `#code`. The native layer raises the matching subclass based on the
  # core `MicrosandboxError` variant; unmapped variants surface as `Error`.
  class Error < StandardError
    CODE = "microsandbox-error"

    # The stable, machine-readable error code for this class.
    def self.code
      const_get(:CODE)
    end

    # The stable, machine-readable error code for this instance.
    def code
      self.class.code
    end
  end

  # Defines `Microsandbox::<name>` as a subclass of `parent` carrying `code`.
  def self.define_error(name, code, parent = Error)
    klass = Class.new(parent)
    klass.const_set(:CODE, code)
    const_set(name, klass)
  end
  private_class_method :define_error

  # Configuration / validation errors --------------------------------------
  define_error(:InvalidConfigError, "invalid-config")

  # Lifecycle errors --------------------------------------------------------
  define_error(:SandboxNotFoundError, "sandbox-not-found")
  define_error(:SandboxNotRunningError, "sandbox-not-running")
  define_error(:SandboxAlreadyExistsError, "sandbox-already-exists")
  define_error(:SandboxStillRunningError, "sandbox-still-running")

  # Execution errors --------------------------------------------------------
  define_error(:ExecTimeoutError, "exec-timeout")
  define_error(:ExecFailedError, "exec-failed")

  # Filesystem errors -------------------------------------------------------
  define_error(:FilesystemError, "filesystem-error")
  define_error(:PathNotFoundError, "path-not-found")

  # Volume / image errors ---------------------------------------------------
  define_error(:VolumeNotFoundError, "volume-not-found")
  define_error(:VolumeAlreadyExistsError, "volume-already-exists")
  define_error(:ImageNotFoundError, "image-not-found")
  define_error(:ImageInUseError, "image-in-use")
  define_error(:ImagePullFailedError, "image-pull-failed")

  # Snapshot errors ---------------------------------------------------------
  # These go BEYOND the Python SDK mirror (which has no Snapshot classes and
  # collapses all five to its base error) — a deliberate divergence matching the
  # Go SDK's per-variant coverage, so callers can rescue a missing/duplicate/
  # running-source/missing-image/corrupt snapshot specifically. The native layer
  # (ext/microsandbox/src/error.rs) maps the five core Snapshot* variants here.
  define_error(:SnapshotNotFoundError, "snapshot-not-found")
  define_error(:SnapshotAlreadyExistsError, "snapshot-already-exists")
  define_error(:SnapshotSandboxRunningError, "snapshot-sandbox-running")
  define_error(:SnapshotImageMissingError, "snapshot-image-missing")
  define_error(:SnapshotIntegrityError, "snapshot-integrity")

  # Networking / secrets errors ---------------------------------------------
  # NetworkPolicyError now also carries the core's `NetworkBuilder` build/parse
  # error (a `network(|n| ...)` validation failure), which was previously
  # unmapped and fell through to the base Error.
  define_error(:NetworkPolicyError, "network-policy-error")
  define_error(:SecretViolationError, "secret-violation")
  define_error(:TlsError, "tls-error")

  # I/O ---------------------------------------------------------------------
  define_error(:IoError, "io-error")

  # Metrics errors ----------------------------------------------------------
  define_error(:MetricsDisabledError, "metrics-disabled")
  define_error(:MetricsUnavailableError, "metrics-unavailable")

  # Runtime compatibility ---------------------------------------------------
  define_error(:UnsupportedOperationError, "unsupported-operation")

  # Cloud / backend routing errors (v0.5.8) ---------------------------------
  # `UnsupportedError` (a backend feature gap, e.g. an op not yet wired on the
  # cloud backend) is distinct from `UnsupportedOperationError` above.
  define_error(:CloudHttpError, "cloud-http")
  define_error(:UnsupportedError, "unsupported")
end
