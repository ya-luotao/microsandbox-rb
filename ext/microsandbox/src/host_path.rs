//! Pin caller-supplied host paths when a sandbox is created (GHSA-mcw9-9rf6-p4rm).
//!
//! Runtimes before v0.7.6 stored a relative host path exactly as written and
//! resolved it against the working directory of whichever process later
//! started the sandbox, so restarting from another directory mounted a
//! different host directory than the one the caller meant. Upstream fixed that
//! in v0.7.6 by resolving host paths once, at the local-backend boundary,
//! before the configuration is persisted. The binding added the same
//! resolution in 0.17.1 and keeps it: it is idempotent with upstream's (an
//! anchored path is absolute, which upstream leaves alone), so the contract
//! does not depend on which layer does it.
//!
//! Rules, matching upstream's `resolve_host_paths`:
//!
//! - Local backend only: on a cloud backend the paths belong to the remote
//!   host and are forwarded untouched.
//! - `std::path::absolute`, never `canonicalize`: anchoring must not follow
//!   symlinks (that would defeat the default refusal to follow a symlinked
//!   bind-mount root) and must not require the target to exist.
//! - Only create-time input is resolved. A sandbox that was already persisted
//!   with a relative path keeps it; nothing here rewrites saved state.
//!
//! The same anchoring applies to `Sandbox.restore`'s snapshot path and
//! `snapshot_base:` (upstream resolves those at the same boundary).
//!
//! A vsock `host_socket` is deliberately not routed through here: the core
//! refuses a relative one outright ("vsock host path must be absolute") before
//! anything is persisted, so there is no stored relative path to pin.

use std::path::PathBuf;

use magnus::Error;
use microsandbox::sandbox::{IntoImage, RootfsSource};
use microsandbox::{BackendKind, MicrosandboxError};

use crate::error;

/// How the `image:` text should be handed to the builder.
pub enum Image {
    /// An OCI reference, an already-absolute path, or text the core rejects —
    /// passed through unchanged so the core classifies (or reports) it.
    Text(String),
    /// A relative local rootfs path, anchored to the current directory.
    Path(PathBuf),
}

/// Resolves host paths for one create call.
#[derive(Clone, Copy)]
pub struct HostPaths {
    local: bool,
}

impl HostPaths {
    /// Capture which backend the create call is about to dispatch to. A
    /// misconfigured selection reports `Cloud` from `kind()` (runtime v0.7.x),
    /// so paths pass through untouched — and the create itself then fails with
    /// that configuration error before anything is persisted.
    pub fn for_default_backend() -> Result<Self, Error> {
        crate::backend::ensure_this_process_backend()?;
        Ok(Self {
            local: matches!(microsandbox::default_backend().kind(), BackendKind::Local),
        })
    }

    /// Anchor a relative host path to the current directory. Absolute paths
    /// and the empty string (left for the core to reject) pass through.
    pub fn pin(self, raw: String, label: &str) -> Result<PathBuf, Error> {
        let path = PathBuf::from(raw);
        if !self.local || path.as_os_str().is_empty() || path.is_absolute() {
            return Ok(path);
        }
        std::path::absolute(&path).map_err(|e| {
            error::to_ruby(MicrosandboxError::InvalidConfig(format!(
                "cannot resolve {label} {}: {e}",
                path.display()
            )))
        })
    }

    /// Pin a `Sandbox.restore` snapshot selector (or `snapshot_base:`) when it
    /// names a path rather than an id, a `group:member` or a digest. Mirrors
    /// v0.7.14's `resolve_snapshot_reference` for an auto reference: a value
    /// that contains `/` or starts with `.` or `~` (the core's
    /// `looks_like_path`), or that names an existing file (a bare archive
    /// name in the current directory), is a path. (The core does not expand
    /// `~`; like any other relative path it is anchored as written.)
    pub fn pin_snapshot(self, raw: String) -> Result<String, Error> {
        let path_like = raw.contains('/')
            || raw.starts_with('.')
            || raw.starts_with('~')
            || std::path::Path::new(&raw).is_file();
        if !path_like {
            return Ok(raw);
        }
        Ok(self
            .pin(raw, "snapshot path")?
            .to_string_lossy()
            .into_owned())
    }

    /// Classify `image:` text the way the core does and pin it when it names a
    /// relative local path (a directory rootfs or a disk image).
    pub fn pin_image(self, text: String) -> Result<Image, Error> {
        if !self.local {
            return Ok(Image::Text(text));
        }
        let relative_local = matches!(
            text.as_str().into_rootfs_source(),
            Ok(RootfsSource::Bind { ref path, .. } | RootfsSource::DiskImage { ref path, .. })
                if path.is_relative()
        );
        if relative_local {
            self.pin(text, "rootfs path").map(Image::Path)
        } else {
            Ok(Image::Text(text))
        }
    }
}
