//! Raw agent client: `Microsandbox::Native::AgentClient`.
//!
//! Mirrors `sdk/python/src/agent.rs`. Wraps the core `AgentBridge` — the
//! FFI-shaped, bytes-in/bytes-out façade over a sandbox's agentd relay socket.
//! Frames are moved as raw CBOR bodies; (de)serialization stays in Ruby. Streams
//! are referenced by opaque `u64` handles so the Ruby layer never owns a tokio
//! receiver. Every call runs on the shared tokio runtime with the GVL released.

use std::sync::Arc;
use std::time::Duration;

use magnus::{function, method, prelude::*, Error, RHash, RModule, RString, Ruby};
use microsandbox::agent::AgentClient as CoreAgentClient;
use microsandbox::{AgentBridge, BridgeFrame, MicrosandboxError};

use crate::error;
use crate::runtime::{block_on, ruby};

/// Map an agent-client error onto the Ruby exception hierarchy (via the core
/// `MicrosandboxError::AgentClient` wrapper, exactly like the Python binding).
fn to_ruby_agent(err: microsandbox::AgentClientError) -> Error {
    error::to_ruby(MicrosandboxError::AgentClient(err))
}

#[magnus::wrap(class = "Microsandbox::Native::AgentClient", free_immediately, size)]
pub struct AgentClient {
    inner: Arc<AgentBridge>,
}

impl AgentClient {
    fn from_bridge(bridge: AgentBridge) -> Self {
        Self {
            inner: Arc::new(bridge),
        }
    }

    //----------------------------------------------------------------------
    // Connection (singleton methods)
    //----------------------------------------------------------------------

    /// Connect to a running sandbox by name. `timeout` is optional seconds.
    fn connect_sandbox(name: String, timeout: Option<f64>) -> Result<AgentClient, Error> {
        let bridge = match dur(timeout)? {
            Some(t) => block_on(AgentBridge::connect_sandbox_with_timeout(&name, t)),
            None => block_on(AgentBridge::connect_sandbox(&name)),
        }
        .map_err(to_ruby_agent)?;
        Ok(AgentClient::from_bridge(bridge))
    }

    /// Connect to an agentd relay socket by path. `timeout` is optional seconds.
    fn connect_path(path: String, timeout: Option<f64>) -> Result<AgentClient, Error> {
        let bridge = match dur(timeout)? {
            Some(t) => block_on(AgentBridge::connect_path_with_timeout(&path, t)),
            None => block_on(AgentBridge::connect_path(&path)),
        }
        .map_err(to_ruby_agent)?;
        Ok(AgentClient::from_bridge(bridge))
    }

    /// Resolve a sandbox's agent relay socket path without connecting.
    fn socket_path(name: String) -> Result<String, Error> {
        let path = CoreAgentClient::socket_path(&name).map_err(error::to_ruby)?;
        Ok(path.to_string_lossy().into_owned())
    }

    //----------------------------------------------------------------------
    // Instance methods
    //----------------------------------------------------------------------

    /// Send one frame and await a single response frame ({id, flags, body}).
    fn request(&self, flags: u8, body: RString) -> Result<RHash, Error> {
        let body = unsafe { body.as_slice() }.to_vec();
        let inner = Arc::clone(&self.inner);
        let frame =
            block_on(async move { inner.request(flags, body).await }).map_err(to_ruby_agent)?;
        Ok(frame_to_hash(frame))
    }

    /// Open a streaming session; returns {id, handle}.
    fn stream_open(&self, flags: u8, body: RString) -> Result<RHash, Error> {
        let body = unsafe { body.as_slice() }.to_vec();
        let inner = Arc::clone(&self.inner);
        let (id, handle) =
            block_on(async move { inner.stream_open(flags, body).await }).map_err(to_ruby_agent)?;
        let hash = ruby().hash_new();
        hash.aset("id", id)?;
        hash.aset("handle", handle)?;
        Ok(hash)
    }

    /// Pull the next frame from a stream; nil at end-of-stream.
    fn stream_next(&self, handle: u64) -> Result<Option<RHash>, Error> {
        let inner = Arc::clone(&self.inner);
        let frame =
            block_on(async move { inner.stream_next(handle).await }).map_err(to_ruby_agent)?;
        Ok(frame.map(frame_to_hash))
    }

    /// Close a stream handle. Idempotent.
    fn stream_close(&self, handle: u64) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        block_on(async move { inner.stream_close(handle).await });
        Ok(())
    }

    /// Send a follow-up frame on an existing correlation id.
    fn send(&self, id: u32, flags: u8, body: RString) -> Result<(), Error> {
        let body = unsafe { body.as_slice() }.to_vec();
        let inner = Arc::clone(&self.inner);
        block_on(async move { inner.send(id, flags, body).await }).map_err(to_ruby_agent)
    }

    /// Cached handshake `core.ready` frame body bytes (CBOR).
    fn ready_bytes(&self) -> Result<RString, Error> {
        let bytes = self.inner.ready_bytes().map_err(to_ruby_agent)?;
        Ok(ruby().str_from_slice(&bytes))
    }

    /// Close the connection. Idempotent.
    fn close(&self) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        block_on(async move { inner.close().await });
        Ok(())
    }
}

/// Convert an optional `timeout` (seconds) into an optional `Duration`,
/// mirroring the Python SDK's `timeout_duration`:
///   - absent (`nil`) → `None` → the core's default handshake timeout
///   - `0` → an explicit zero deadline (fail fast), *not* "use the default"
///   - negative or non-finite (NaN/Inf) → a caller error (rather than being
///     silently swallowed into the default)
fn dur(timeout: Option<f64>) -> Result<Option<Duration>, Error> {
    match timeout {
        None => Ok(None),
        Some(t) if t.is_finite() && t >= 0.0 => Ok(Some(Duration::from_secs_f64(t))),
        Some(t) => Err(error::base_error(format!(
            "timeout must be a non-negative, finite number of seconds (got {t})"
        ))),
    }
}

/// Shape a `BridgeFrame` into a Ruby Hash. `body` is binary (ASCII-8BIT).
fn frame_to_hash(frame: BridgeFrame) -> RHash {
    let r = ruby();
    let hash = r.hash_new();
    let _ = hash.aset("id", frame.id);
    let _ = hash.aset("flags", frame.flags);
    let _ = hash.aset("body", r.str_from_slice(&frame.body));
    hash
}

pub fn define(ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    let class = native.define_class("AgentClient", ruby.class_object())?;

    class.define_singleton_method(
        "connect_sandbox",
        function!(AgentClient::connect_sandbox, 2),
    )?;
    class.define_singleton_method("connect_path", function!(AgentClient::connect_path, 2))?;
    class.define_singleton_method("socket_path", function!(AgentClient::socket_path, 1))?;

    class.define_method("request", method!(AgentClient::request, 2))?;
    class.define_method("stream_open", method!(AgentClient::stream_open, 2))?;
    class.define_method("stream_next", method!(AgentClient::stream_next, 1))?;
    class.define_method("stream_close", method!(AgentClient::stream_close, 1))?;
    class.define_method("send", method!(AgentClient::send, 3))?;
    class.define_method("ready_bytes", method!(AgentClient::ready_bytes, 0))?;
    class.define_method("close", method!(AgentClient::close, 0))?;

    Ok(())
}
