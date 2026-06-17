//! Named persistent volume management: `Microsandbox::Native::Volume`.
//!
//! Mirrors `sdk/python/src/volume.rs`. Static async CRUD over the volume store;
//! results are returned as plain Ruby Hashes/Arrays.

use magnus::{function, prelude::*, Error, RArray, RHash, RModule, Ruby};
use microsandbox::volume::VolumeHandle;

use crate::conv;
use crate::error;
use crate::runtime::{block_on, ruby};

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
    hash.aset("path", vol.path().display().to_string())?;
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

pub fn define(ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    let class = native.define_class("Volume", ruby.class_object())?;
    class.define_singleton_method("create", function!(create, 2))?;
    class.define_singleton_method("get", function!(get, 1))?;
    class.define_singleton_method("list", function!(list, 0))?;
    class.define_singleton_method("remove", function!(remove, 1))?;
    Ok(())
}
