//! Named persistent volume management: `Microsandbox::Native::Volume`.
//!
//! Mirrors `sdk/python/src/volume.rs`. Static async CRUD over the volume store;
//! results are returned as plain Ruby Hashes/Arrays.

use std::sync::Arc;

use magnus::{function, method, prelude::*, Error, RArray, RHash, RModule, RString, Ruby};
use microsandbox::volume::VolumeHandle;
use microsandbox::Backend;

use crate::backend::local_backend;
use crate::conv;
use crate::error;
use crate::runtime::{block_on, ruby};
use crate::sandbox::{fs_entry_to_hash, fs_metadata_to_hash};

fn handle_to_hash(h: &VolumeHandle) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("name", h.name().to_string());
    let _ = hash.aset("kind", h.kind().as_str().to_string());
    let _ = hash.aset("quota_mib", h.quota_mib());
    let _ = hash.aset("used_bytes", h.used_bytes());
    let _ = hash.aset("capacity_bytes", h.capacity_bytes());
    let _ = hash.aset("disk_format", h.disk_format().map(str::to_string));
    let _ = hash.aset("disk_fstype", h.disk_fstype().map(str::to_string));
    let _ = hash.aset(
        "created_at_ms",
        h.created_at().map(|dt| dt.timestamp_millis()),
    );
    let labels = ruby().hash_new();
    for (k, v) in h.labels().iter() {
        let _ = labels.aset(k.clone(), v.clone());
    }
    let _ = hash.aset("labels", labels);
    hash
}

/// Create a named volume. `opts`: kind ("dir"|"disk"), size_mib, quota_mib, labels.
fn create(name: String, opts: RHash) -> Result<RHash, Error> {
    let mut builder = microsandbox::Volume::builder(&name);
    let kind = conv::opt_string(opts, "kind")?.unwrap_or_else(|| "dir".to_string());
    let size_mib = conv::opt_u32(opts, "size_mib")?;

    match kind.as_str() {
        "dir" => {
            builder = builder.directory();
            if size_mib.is_some() {
                return Err(error::base_error(
                    "size_mib is only supported with kind: \"disk\"",
                ));
            }
        }
        "disk" => {
            builder = builder.disk();
            let size = size_mib
                .ok_or_else(|| error::base_error("size_mib is required with kind: \"disk\""))?;
            builder = builder.size(size);
        }
        other => return Err(error::base_error(format!("unknown volume kind: {other:?}"))),
    }

    if let Some(quota) = conv::opt_u32(opts, "quota_mib")? {
        builder = builder.quota(quota);
    }
    for (k, v) in conv::opt_string_map(opts, "labels")? {
        builder = builder.label(k, v);
    }

    let vol = block_on(builder.create()).map_err(error::to_ruby)?;
    let hash = ruby().hash_new();
    hash.aset("name", vol.name().to_string())?;
    // `path()` is fallible as of v0.5.8 (returns `Unsupported` for cloud
    // volumes); the volume just created here is local, so this resolves.
    hash.aset(
        "path",
        vol.path().map_err(error::to_ruby)?.display().to_string(),
    )?;
    Ok(hash)
}

fn get(name: String) -> Result<RHash, Error> {
    let handle = block_on(microsandbox::Volume::get(&name)).map_err(error::to_ruby)?;
    Ok(handle_to_hash(&handle))
}

fn list() -> Result<RArray, Error> {
    let handles = block_on(microsandbox::Volume::list()).map_err(error::to_ruby)?;
    let arr = ruby().ary_new();
    for h in handles.iter() {
        arr.push(handle_to_hash(h))?;
    }
    Ok(arr)
}

fn remove(name: String) -> Result<(), Error> {
    block_on(microsandbox::Volume::remove(&name)).map_err(error::to_ruby)
}

/// A host-side filesystem view over a named volume — read/write its contents
/// without a running sandbox. Mirrors the Python `VolumeFs` / Node `VolumeFs`.
/// The core `VolumeFs<'a>` borrows the volume name, so (like the Python binding)
/// each operation rebuilds it from the stored backend + name.
#[magnus::wrap(class = "Microsandbox::Native::VolumeFs", free_immediately, size)]
pub struct VolumeFs {
    backend: Arc<dyn Backend>,
    name: String,
}

impl VolumeFs {
    /// Resolve the (local) backend once and bind it to `name`.
    fn for_volume(name: String) -> Result<VolumeFs, Error> {
        Ok(VolumeFs {
            backend: local_backend().map_err(error::to_ruby)?,
            name,
        })
    }

    fn fs(&self) -> microsandbox::volume::VolumeFs<'_> {
        microsandbox::volume::VolumeFs::with_backend(self.backend.clone(), &self.name)
    }

    fn read(&self, path: String) -> Result<RString, Error> {
        let fs = self.fs();
        let bytes = block_on(fs.read(&path)).map_err(error::to_ruby)?;
        Ok(ruby().str_from_slice(bytes.as_ref()))
    }

    fn read_text(&self, path: String) -> Result<String, Error> {
        let fs = self.fs();
        block_on(fs.read_to_string(&path)).map_err(error::to_ruby)
    }

    fn write(&self, path: String, data: RString) -> Result<(), Error> {
        // Copy the bytes out while the GVL is held (GC.compact could move them).
        let bytes = unsafe { data.as_slice() }.to_vec();
        let fs = self.fs();
        block_on(fs.write(&path, &bytes)).map_err(error::to_ruby)
    }

    fn list(&self, path: String) -> Result<RArray, Error> {
        let fs = self.fs();
        let entries = block_on(fs.list(&path)).map_err(error::to_ruby)?;
        let arr = ruby().ary_new();
        for entry in &entries {
            arr.push(fs_entry_to_hash(entry))?;
        }
        Ok(arr)
    }

    fn mkdir(&self, path: String) -> Result<(), Error> {
        let fs = self.fs();
        block_on(fs.mkdir(&path)).map_err(error::to_ruby)
    }

    fn remove_file(&self, path: String) -> Result<(), Error> {
        let fs = self.fs();
        block_on(fs.remove(&path)).map_err(error::to_ruby)
    }

    fn remove_dir(&self, path: String) -> Result<(), Error> {
        let fs = self.fs();
        block_on(fs.remove_dir(&path)).map_err(error::to_ruby)
    }

    fn exists(&self, path: String) -> Result<bool, Error> {
        let fs = self.fs();
        block_on(fs.exists(&path)).map_err(error::to_ruby)
    }

    fn copy(&self, from: String, to: String) -> Result<(), Error> {
        let fs = self.fs();
        block_on(fs.copy(&from, &to)).map_err(error::to_ruby)
    }

    fn rename(&self, from: String, to: String) -> Result<(), Error> {
        let fs = self.fs();
        block_on(fs.rename(&from, &to)).map_err(error::to_ruby)
    }

    fn stat(&self, path: String) -> Result<RHash, Error> {
        let fs = self.fs();
        let meta = block_on(fs.stat(&path)).map_err(error::to_ruby)?;
        Ok(fs_metadata_to_hash(&meta))
    }
}

/// Open a host-side filesystem view over a named volume.
fn fs(name: String) -> Result<VolumeFs, Error> {
    VolumeFs::for_volume(name)
}

pub fn define(ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    let class = native.define_class("Volume", ruby.class_object())?;
    class.define_singleton_method("create", function!(create, 2))?;
    class.define_singleton_method("get", function!(get, 1))?;
    class.define_singleton_method("list", function!(list, 0))?;
    class.define_singleton_method("remove", function!(remove, 1))?;
    class.define_singleton_method("fs", function!(fs, 1))?;

    let vfs = native.define_class("VolumeFs", ruby.class_object())?;
    vfs.define_method("read", method!(VolumeFs::read, 1))?;
    vfs.define_method("read_text", method!(VolumeFs::read_text, 1))?;
    vfs.define_method("write", method!(VolumeFs::write, 2))?;
    vfs.define_method("list", method!(VolumeFs::list, 1))?;
    vfs.define_method("mkdir", method!(VolumeFs::mkdir, 1))?;
    vfs.define_method("remove_file", method!(VolumeFs::remove_file, 1))?;
    vfs.define_method("remove_dir", method!(VolumeFs::remove_dir, 1))?;
    vfs.define_method("exists", method!(VolumeFs::exists, 1))?;
    vfs.define_method("copy", method!(VolumeFs::copy, 2))?;
    vfs.define_method("rename", method!(VolumeFs::rename, 2))?;
    vfs.define_method("stat", method!(VolumeFs::stat, 1))?;
    Ok(())
}
