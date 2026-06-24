//! Streaming guest-filesystem I/O: `Microsandbox::Native::FsReadStream` and
//! `Microsandbox::Native::FsWriteSink`.
//!
//! Wraps the core `SandboxFs::read_stream`/`write_stream` handles so large files
//! can be moved without buffering the whole thing in memory. The core
//! `FsReadStream::recv` needs `&mut self` and `FsWriteSink::close` consumes
//! `self`, so each is held behind a `tokio::Mutex` (the sink as an `Option`, so
//! `close` can take it and be idempotent). Each call drives the future to
//! completion with the GVL released; the Ruby layer wraps these as an
//! `Enumerable` reader and a writer with a block form.

use std::sync::Arc;

use magnus::{method, prelude::*, Error, RModule, RString, Ruby};
use microsandbox::sandbox::{FsReadStream, FsWriteSink};
use tokio::sync::Mutex;

use crate::error;
use crate::runtime::{block_on, ruby};

#[magnus::wrap(class = "Microsandbox::Native::FsReadStream", free_immediately, size)]
pub struct FsReadStreamHandle {
    inner: Arc<Mutex<FsReadStream>>,
}

impl FsReadStreamHandle {
    pub fn new(stream: FsReadStream) -> Self {
        Self {
            inner: Arc::new(Mutex::new(stream)),
        }
    }

    /// Next chunk of bytes (ASCII-8BIT), or nil at end of stream.
    fn recv(&self) -> Result<Option<RString>, Error> {
        let inner = Arc::clone(&self.inner);
        match block_on(async move { inner.lock().await.recv().await }).map_err(error::to_ruby)? {
            Some(bytes) => Ok(Some(ruby().str_from_slice(bytes.as_ref()))),
            None => Ok(None),
        }
    }
}

#[magnus::wrap(class = "Microsandbox::Native::FsWriteSink", free_immediately, size)]
pub struct FsWriteSinkHandle {
    inner: Arc<Mutex<Option<FsWriteSink>>>,
}

impl FsWriteSinkHandle {
    pub fn new(sink: FsWriteSink) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Some(sink))),
        }
    }

    /// Write a chunk of bytes. Errors if the sink is already closed.
    fn write(&self, data: RString) -> Result<(), Error> {
        // Copy out while the GVL is held (GC.compact could move the buffer).
        let bytes = unsafe { data.as_slice() }.to_vec();
        let inner = Arc::clone(&self.inner);
        let result = block_on(async move {
            let guard = inner.lock().await;
            match guard.as_ref() {
                Some(sink) => Some(sink.write(&bytes).await),
                None => None,
            }
        });
        match result {
            Some(r) => r.map_err(error::to_ruby),
            None => Err(error::base_error("write to a closed FsWriteSink")),
        }
    }

    /// Flush and close the sink. Idempotent.
    fn close(&self) -> Result<(), Error> {
        let inner = Arc::clone(&self.inner);
        let taken = block_on(async move { inner.lock().await.take() });
        match taken {
            Some(sink) => block_on(sink.close()).map_err(error::to_ruby),
            None => Ok(()),
        }
    }
}

pub fn define(ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    let rs = native.define_class("FsReadStream", ruby.class_object())?;
    rs.define_method("recv", method!(FsReadStreamHandle::recv, 0))?;

    let ws = native.define_class("FsWriteSink", ruby.class_object())?;
    ws.define_method("write", method!(FsWriteSinkHandle::write, 1))?;
    ws.define_method("close", method!(FsWriteSinkHandle::close, 0))?;
    Ok(())
}
