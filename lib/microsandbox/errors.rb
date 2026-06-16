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
  define_error(:ImageNotFoundError, "image-not-found")
  define_error(:ImageInUseError, "image-in-use")
  define_error(:ImagePullFailedError, "image-pull-failed")

  # Networking / secrets errors ---------------------------------------------
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
end
