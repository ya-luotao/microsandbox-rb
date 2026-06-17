//! Streaming logs and metrics: `Microsandbox::Native::LogStream` and
//! `Microsandbox::Native::MetricsStream`.
//!
//! Mirrors the `ExecHandle` streaming pattern in `exec.rs`. The core
//! `log_stream`/`metrics_stream` return `impl Stream`; we box+pin each into an
//! `Arc<tokio::Mutex<…>>` and expose a synchronous `recv` that drives the next
//! item to completion with the GVL released, returning a Ruby Hash (or `nil` at
//! end of stream). The Ruby layer wraps each as an `Enumerable`.

use std::pin::Pin;
use std::sync::Arc;

use futures::Stream;
use magnus::{method, prelude::*, Error, RHash, RModule, Ruby};
use microsandbox::logs::LogEntry;
use microsandbox::sandbox::SandboxMetrics;
use microsandbox::MicrosandboxResult;
use tokio::sync::Mutex;

use crate::error;
use crate::runtime::block_on;
use crate::sandbox::{log_entry_to_hash, metrics_to_hash};

type BoxStream<T> = Pin<Box<dyn Stream<Item = MicrosandboxResult<T>> + Send>>;

#[magnus::wrap(class = "Microsandbox::Native::LogStream", free_immediately, size)]
pub struct LogStream {
    inner: Arc<Mutex<BoxStream<LogEntry>>>,
}

impl LogStream {
    pub fn from_stream(
        stream: impl Stream<Item = MicrosandboxResult<LogEntry>> + Send + 'static,
    ) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Box::pin(stream))),
        }
    }

    /// Next log entry as a Hash, or nil when the stream ends.
    fn recv(&self) -> Result<Option<RHash>, Error> {
        use futures::StreamExt;
        let inner = Arc::clone(&self.inner);
        match block_on(async move { inner.lock().await.next().await }) {
            Some(Ok(entry)) => Ok(Some(log_entry_to_hash(&entry))),
            Some(Err(e)) => Err(error::to_ruby(e)),
            None => Ok(None),
        }
    }
}

#[magnus::wrap(class = "Microsandbox::Native::MetricsStream", free_immediately, size)]
pub struct MetricsStream {
    inner: Arc<Mutex<BoxStream<SandboxMetrics>>>,
}

impl MetricsStream {
    pub fn from_stream(
        stream: impl Stream<Item = MicrosandboxResult<SandboxMetrics>> + Send + 'static,
    ) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Box::pin(stream))),
        }
    }

    /// Next metrics snapshot as a Hash, or nil when the stream ends.
    fn recv(&self) -> Result<Option<RHash>, Error> {
        use futures::StreamExt;
        let inner = Arc::clone(&self.inner);
        match block_on(async move { inner.lock().await.next().await }) {
            Some(Ok(metrics)) => Ok(Some(metrics_to_hash(&metrics))),
            Some(Err(e)) => Err(error::to_ruby(e)),
            None => Ok(None),
        }
    }
}

pub fn define(ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    let logs = native.define_class("LogStream", ruby.class_object())?;
    logs.define_method("recv", method!(LogStream::recv, 0))?;

    let metrics = native.define_class("MetricsStream", ruby.class_object())?;
    metrics.define_method("recv", method!(MetricsStream::recv, 0))?;

    Ok(())
}
