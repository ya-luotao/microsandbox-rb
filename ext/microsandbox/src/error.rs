//! Map the core `MicrosandboxError` enum onto the Ruby exception hierarchy.
//!
//! Mirrors `sdk/python/src/error.rs`: each handled variant is routed to a
//! specific `Microsandbox::*Error` class (defined in `lib/microsandbox/errors.rb`),
//! every other variant falls back to the base `Microsandbox::Error`. The message
//! is always the core error's `to_string()`.

use magnus::{value::ReprValue, Error, ExceptionClass, Module, RClass, RModule, Ruby};
use microsandbox::{AgentClientError, MicrosandboxError};

/// The Ruby class (relative to the `Microsandbox` module) for a core error.
/// `"Error"` is the base class; anything else is a named subclass.
fn class_name(err: &MicrosandboxError) -> &'static str {
    use MicrosandboxError::*;
    match err {
        InvalidConfig(_) => "InvalidConfigError",
        SandboxNotFound(_) => "SandboxNotFoundError",
        SandboxAlreadyExists(_) => "SandboxAlreadyExistsError",
        SandboxStillRunning(_) => "SandboxStillRunningError",
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

    match exception_class(&ruby, class_name(&err)) {
        Some(class) => Error::new(class, message),
        None => Error::new(ruby.exception_runtime_error(), message),
    }
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
