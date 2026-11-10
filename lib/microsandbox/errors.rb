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

  # Host runtime resolution (runtime v0.7) -----------------------------------
  # No `msb` + `libkrunfw` pair could be found anywhere. Mirrors the Python
  # SDK's RuntimeNotInstalledError.
  define_error(:RuntimeNotInstalledError, "runtime-not-installed")
  # The selected runtime pair is partial, or an explicit `MSB_PATH` /
  # `runtime_path` names an executable with no matching `libkrunfw`. Mirrors
  # the Python SDK's RuntimeIncompleteError.
  define_error(:RuntimeIncompleteError, "runtime-incomplete")

  # Lifecycle errors --------------------------------------------------------
  define_error(:SandboxNotFoundError, "sandbox-not-found")
  define_error(:SandboxNotRunningError, "sandbox-not-running")
  define_error(:SandboxAlreadyExistsError, "sandbox-already-exists")
  define_error(:SandboxStillRunningError, "sandbox-still-running")
  # v0.6.16: a lifecycle operation was aimed at a sandbox identity that no
  # longer owns the name — the name was removed and recreated behind the
  # caller's back. Raised by the identity-checked convergent APIs
  # (`wait_for_status`, `restart`, `destroy`, `connect_or_start`) rather than
  # letting them act on the replacement. Mirrors the Python SDK's
  # SandboxReplacedError.
  define_error(:SandboxReplacedError, "sandbox-replaced")
  # v0.7: a graceful stop did not establish completion within its budget; the
  # shutdown request may still complete, and no kill was requested. Mirrors
  # the Python SDK's StopTimeoutError (kept flat here: no TimeoutError mixin).
  define_error(:StopTimeoutError, "stop-timeout")
  # Reserved for parity (Python SandboxStopTimedOutError): the core variant has
  # no raise site at the pinned runtime.
  define_error(:SandboxStopTimedOutError, "sandbox-stop-timed-out")

  # Execution errors --------------------------------------------------------
  define_error(:ExecTimeoutError, "exec-timeout")
  define_error(:ExecFailedError, "exec-failed")
  # v0.6.9: `exec_default`/`attach_default` on an image whose resolved
  # ENTRYPOINT+CMD provide no executable command. Mirrors the Python SDK's
  # NoDefaultCommandError.
  define_error(:NoDefaultCommandError, "no-default-command")

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
  # v0.6.7: the automatic v0.6.6→v0.6.7 snapshot-descriptor migration (run at
  # backend connect / artifact open) was blocked and needs repair. Mirrors the
  # Python SDK's SnapshotMigrationError (code "snapshot-migration").
  define_error(:SnapshotMigrationError, "snapshot-migration")
  # v0.7: a full checkpoint was captured, but the source sandbox failed to
  # recover afterwards and needs recovery before further use. Carries the
  # recovery locator as attributes (see the class body below). Mirrors the
  # Python SDK's SnapshotSourceRecoveryError.
  define_error(:SnapshotSourceRecoveryError, "snapshot-source-recovery")

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
  # v0.7 (cloud only): a change did not complete as asked — it may be saved
  # without being in effect on the running sandbox, or its outcome is unknown.
  # The message says which and whether resending retries it; it never holds a
  # secret value. Mirrors the Python SDK's ModificationNotConfirmedError.
  define_error(:ModificationNotConfirmedError, "modification-not-confirmed")

  # Process model ------------------------------------------------------------
  # A handle (a Sandbox, a SandboxHandle, an ExecHandle, a stream, an SSH or
  # agent client, a VolumeFs, ...) was used in a process forked from the one
  # that created it. Handles are bound to their creating process; a forked
  # child opens its own (`Sandbox.get(name).connect`, `Volume.fs(name)`, ...).
  # The message names both pids. Ruby-only: no other SDK has a counterpart.
  define_error(:ForkedHandleError, "forked-handle")

  # As of runtime v0.6.8 the core keys Unsupported errors by a structured
  # (operation, reason) pair. The native layer renders both into the message
  # ("sandbox.kill is not supported by this backend: ...") and also attaches
  # them here as structured attributes, mirroring the Python SDK's
  # `UnsupportedError.operation` / `.hint`.
  class UnsupportedError
    # @return [String, nil] the rejected API in Ruby rendering, e.g. "sandbox.kill"
    attr_reader :operation
    # @return [String, nil] why it was rejected / what to use instead
    attr_reader :hint
  end

  # Capture completed, but the source requires recovery before further use.
  # {#artifact} is set only when the requested snapshot was published;
  # otherwise {#checkpoint_path} locates the retained runtime-local checkpoint
  # (removing the source may remove it). The error does not imply that an
  # ordinary resume is safe.
  class SnapshotSourceRecoveryError
    # @return [String, nil] sandbox whose post-capture recovery failed
    attr_reader :source_sandbox
    # @return [String, nil] verified runtime checkpoint id
    attr_reader :checkpoint_id
    # @return [String, nil] content-addressed root of that checkpoint
    attr_reader :checkpoint_root
    # @return [String, nil] runtime-local checkpoint path
    attr_reader :checkpoint_path
    # @return [Hash, nil] the published artifact, when publication completed:
    #   `{"kind" => "installed" | "archive", "path" =>, "snapshot_id" =>, "digest" =>}`
    attr_reader :artifact
    # @return [String, nil] the runtime's recovery diagnostic
    attr_reader :detail
    # @return [String, nil] a further failure while publishing the artifact
    attr_reader :publication_error

    private

    # Called by the native layer with the core's serialized recovery record.
    def __apply_recovery(details)
      @source_sandbox = details["source_sandbox"]
      @checkpoint_id = details["checkpoint_id"]
      @checkpoint_root = details["checkpoint_root"]
      @checkpoint_path = details["checkpoint_path"]
      @artifact = details["artifact"]
      @detail = details["detail"]
      @publication_error = details["publication_error"]
      self
    end
  end
end
