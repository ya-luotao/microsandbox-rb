//! Map the core `MicrosandboxError` enum onto the Ruby exception hierarchy.
//!
//! Mirrors `sdk/python/src/error.rs`: each handled variant is routed to a
//! specific `Microsandbox::*Error` class (defined in `lib/microsandbox/errors.rb`),
//! every other variant falls back to the base `Microsandbox::Error`. The message
//! is always the core error's `to_string()`.

use magnus::{value::ReprValue, Error, ExceptionClass, Module, RClass, RModule, Ruby};
use microsandbox::{AgentClientError, MicrosandboxError, Operation, UnsupportedReason};
use microsandbox_network::policy::BuildError;

/// The Ruby class (relative to the `Microsandbox` module) for a core error.
/// `"Error"` is the base class; anything else is a named subclass.
fn class_name(err: &MicrosandboxError) -> &'static str {
    use MicrosandboxError::*;
    match err {
        InvalidConfig(_) => "InvalidConfigError",
        SandboxNotFound(_) => "SandboxNotFoundError",
        SandboxAlreadyExists(_) => "SandboxAlreadyExistsError",
        SandboxStillRunning(_) => "SandboxStillRunningError",
        // v0.6.16 (#1462): the receiver's captured identity no longer owns the
        // name — it was removed and recreated. Raised by the identity-checked
        // convergent lifecycle APIs instead of acting on the replacement.
        // Mirrors the Python `SandboxReplacedError`.
        SandboxReplaced { .. } => "SandboxReplacedError",
        // v0.6.6 (#1099): the sandbox exists but isn't running. Raised by the
        // handle's exec/attach/ping/touch not-running guards and the fs
        // agent-endpoint lookup. The `SandboxNotRunningError` class already
        // existed (mirroring the Python SDK); this wires the new core variant to
        // it instead of letting it collapse to the base `Error`.
        SandboxNotRunning(_) => "SandboxNotRunningError",
        ExecTimeout(_) => "ExecTimeoutError",
        ExecFailed(_) => "ExecFailedError",
        SandboxFsOps(_) => "FilesystemError",
        ImageNotFound(_) => "ImageNotFoundError",
        ImageInUse(_) => "ImageInUseError",
        VolumeNotFound(_) => "VolumeNotFoundError",
        VolumeAlreadyExists(_) => "VolumeAlreadyExistsError",
        Io(_) => "IoError",
        MetricsDisabled(_) => "MetricsDisabledError",
        MetricsUnavailable(_) => "MetricsUnavailableError",
        AgentClient(AgentClientError::UnsupportedOperation { .. }) => "UnsupportedOperationError",
        // Backend routing (v0.5.8 / PR #754). `Unsupported` is reachable on the
        // local backend too (e.g. `Volume::path` on a cloud volume, snapshot
        // ops), so it must map even for local-only use. Distinct from the agent
        // client's `UnsupportedOperation` above.
        CloudHttp { .. } => "CloudHttpError",
        Unsupported { .. } => "UnsupportedError",
        // Snapshot operations, all reachable through the gem's fully-wired
        // `Snapshot` API. Upstream raises these un-wrapped, so without a mapping
        // they collapse to the base `Error` and callers must string-match the
        // message. This goes BEYOND the Python mirror (which has no Snapshot
        // classes and matches the Go SDK's per-variant coverage instead) — a
        // deliberate divergence noted in `lib/microsandbox/errors.rb`.
        SnapshotNotFound(_) => "SnapshotNotFoundError",
        SnapshotAlreadyExists(_) => "SnapshotAlreadyExistsError",
        SnapshotSandboxRunning(_) => "SnapshotSandboxRunningError",
        SnapshotImageMissing(_) => "SnapshotImageMissingError",
        SnapshotIntegrity(_) => "SnapshotIntegrityError",
        // v0.6.7 (#1200): the automatic v0.6.6→v0.6.7 snapshot-descriptor
        // migration (run at backend connect / artifact open) failed and needs
        // repair. Mirrors the Python `SnapshotMigrationError`.
        SnapshotMigration { .. } => "SnapshotMigrationError",
        // v0.6.17: a malformed `proxy:` (unparseable `IP:port`, invalid SOCKS4
        // user ID, ...) also arrives as a `NetworkBuilder` error, but it is a
        // *configuration* mistake, not a policy one — route it to
        // `InvalidConfigError` like every other bad create option. Matched on
        // the variant, never on the message text.
        NetworkBuilder(BuildError::InvalidOutboundProxy { .. }) => "InvalidConfigError",
        // Give the already-defined-but-orphaned `NetworkPolicyError` a mapping:
        // a builder parse/validation error from `network(|n| ...)`. The gem
        // unconditionally enables the core's `net` feature (default-features),
        // so this variant is always present.
        NetworkBuilder(_) => "NetworkPolicyError",
        // v0.6.9: `exec_default`/`attach_default` on an image whose resolved
        // ENTRYPOINT+CMD provide no executable command. Mirrors the Python
        // SDK's `NoDefaultCommandError`.
        NoDefaultCommand => "NoDefaultCommandError",
        _ => "Error",
    }
}

/// Look up `Microsandbox::<name>` as an exception class.
fn exception_class(ruby: &Ruby, name: &str) -> Option<ExceptionClass> {
    let module: RModule = ruby.class_object().const_get("Microsandbox").ok()?;
    let class: RClass = module.const_get(name).ok()?;
    ExceptionClass::from_value(class.as_value())
}

/// Convert a core error into a Ruby exception, preserving the typed class.
// The `exception::runtime_error()` fallbacks fire only off a Ruby thread (which
// never happens from a bound method); there is no handle-based alternative there.
#[allow(deprecated)]
pub fn to_ruby(err: MicrosandboxError) -> Error {
    let message = err.to_string();
    let ruby = match Ruby::get() {
        Ok(ruby) => ruby,
        // Not on a Ruby thread (should never happen from a bound method).
        Err(_) => return Error::new(magnus::exception::runtime_error(), message),
    };

    // `Unsupported` gets a Ruby-idiom message (`sandbox.kill` instead of
    // `Sandbox::kill`) plus structured `operation` / `hint` attributes on the
    // exception instance, mirroring the Python SDK's enrichment (v0.6.8).
    if let MicrosandboxError::Unsupported { op, reason } = &err {
        return unsupported_error(&ruby, &ruby_api_name(*op), &ruby_hint(reason));
    }

    match exception_class(&ruby, class_name(&err)) {
        Some(class) => Error::new(class, message),
        None => Error::new(ruby.exception_runtime_error(), message),
    }
}

/// `UnsupportedError` for shim-only entry points that require the local
/// backend but have no SDK [`Operation`] (Ruby-only diagnostic hooks such as
/// `Microsandbox.runtime_path`). `name` is the Ruby-facing API name. Mirrors
/// the Python SDK's name-based `local_only` helper.
#[allow(deprecated)]
pub fn local_only(name: &str) -> Error {
    match Ruby::get() {
        Ok(ruby) => unsupported_error(&ruby, name, "use a local backend"),
        Err(_) => Error::new(
            magnus::exception::runtime_error(),
            format!("{name} is not supported by this backend: use a local backend"),
        ),
    }
}

/// Build a `Microsandbox::UnsupportedError` carrying the rendered message and
/// the structured `@operation` / `@hint` attributes.
fn unsupported_error(ruby: &Ruby, operation: &str, hint: &str) -> Error {
    let message = format!("{operation} is not supported by this backend: {hint}");
    let Some(class) = exception_class(ruby, "UnsupportedError") else {
        return Error::new(ruby.exception_runtime_error(), message);
    };
    match class
        .as_value()
        .funcall::<_, _, magnus::Exception>("new", (message.as_str(),))
    {
        Ok(exc) => {
            // Best-effort extras; the message already carries both.
            let _ = exc
                .funcall::<_, _, magnus::Value>("instance_variable_set", ("@operation", operation));
            let _ = exc.funcall::<_, _, magnus::Value>("instance_variable_set", ("@hint", hint));
            exc.into()
        }
        Err(_) => Error::new(class, message),
    }
}

/// Render an [`Operation`] as the Ruby API it corresponds to: `Sandbox::kill`
/// becomes `sandbox.kill` and `SandboxFsOps::stat_handle` becomes
/// `sandbox_fs_ops.stat_handle`; a parenthetical keeps its Ruby keyword shape
/// (`log_stream(follow=false)` becomes `log_stream(follow: false)`). Plain
/// phrases without a `Type::method` shape (`config`, `snapshot operations`)
/// pass through as-is. Mirrors the Python SDK's `py_api_name`.
fn ruby_api_name(op: Operation) -> String {
    let path = op.api_path();
    let Some((ty, method)) = path.split_once("::") else {
        return path.to_string();
    };
    format!("{}.{}", camel_to_snake(ty), method.replace('=', ": "))
}

/// Render an [`UnsupportedReason`] with `use instead` targets pointing at the
/// Ruby API name rather than the Rust path.
fn ruby_hint(reason: &UnsupportedReason) -> String {
    match reason {
        UnsupportedReason::UseInstead(op) => format!("use {}", ruby_api_name(*op)),
        other => other.hint(),
    }
}

/// Lower a `CamelCase` type name to `snake_case` (`SandboxFsOps` becomes
/// `sandbox_fs_ops`).
fn camel_to_snake(name: &str) -> String {
    let mut out = String::with_capacity(name.len() + 4);
    for (i, ch) in name.char_indices() {
        if ch.is_ascii_uppercase() {
            if i > 0 {
                out.push('_');
            }
            out.push(ch.to_ascii_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}

/// A plain `Microsandbox::Error` (base) with a custom message — used for
/// binding-level validation errors that have no core counterpart.
#[allow(deprecated)]
pub fn base_error(message: impl Into<String>) -> Error {
    let message = message.into();
    match Ruby::get() {
        Ok(ruby) => match exception_class(&ruby, "Error") {
            Some(class) => Error::new(class, message),
            None => Error::new(ruby.exception_runtime_error(), message),
        },
        Err(_) => Error::new(magnus::exception::runtime_error(), message),
    }
}
