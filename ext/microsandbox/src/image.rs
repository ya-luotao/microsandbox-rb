//! OCI image-cache management: `Microsandbox::Native::Image`.
//!
//! Mirrors `sdk/python/src/image.rs`. Static async operations over the cached
//! image store; results are returned as plain Ruby Hashes/Arrays. Note the core
//! `ImageHandle` exposes accessor *methods* while `ImageDetail`/`ImageConfigDetail`/
//! `ImageLayerDetail`/`ImagePruneReport` expose public *fields*.

use magnus::{function, prelude::*, Error, RArray, RHash, RModule, Ruby};
use microsandbox::image::{Image, ImageDetail, ImageHandle, ImagePruneReport};

use crate::backend::with_local_backend;
use crate::conv;
use crate::runtime::ruby;

fn handle_to_hash(h: &ImageHandle) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("reference", h.reference().to_string());
    let _ = hash.aset("size_bytes", h.size_bytes());
    let _ = hash.aset("manifest_digest", h.manifest_digest().map(str::to_string));
    let _ = hash.aset("architecture", h.architecture().map(str::to_string));
    let _ = hash.aset("os", h.os().map(str::to_string));
    let _ = hash.aset("layer_count", h.layer_count());
    let _ = hash.aset(
        "created_at_ms",
        h.created_at().map(|dt| dt.timestamp_millis()),
    );
    let _ = hash.aset(
        "last_used_at_ms",
        h.last_used_at().map(|dt| dt.timestamp_millis()),
    );
    hash
}

fn detail_to_hash(detail: ImageDetail) -> RHash {
    let r = ruby();
    let hash = r.hash_new();
    let _ = hash.aset("handle", handle_to_hash(&detail.handle));

    if let Some(config) = detail.config {
        let c = r.hash_new();
        let _ = c.aset("digest", config.digest);
        let _ = c.aset("env", config.env);
        let _ = c.aset("cmd", config.cmd);
        let _ = c.aset("entrypoint", config.entrypoint);
        let _ = c.aset("working_dir", config.working_dir);
        let _ = c.aset("user", config.user);
        // OCI config labels: a free-form JSON object (or nil). Converted to a
        // Ruby Hash so `ImageDetail#config["labels"]` matches the Python/Node
        // `config.labels` dict. (The pinned v0.5.8 runtime persists this as
        // null today; the key exists for forward-compatibility/parity.)
        let _ = c.aset("labels", config.labels.as_ref().map(conv::json_to_ruby));
        let _ = c.aset("stop_signal", config.stop_signal);
        let _ = hash.aset("config", c);
    } else {
        let _ = hash.aset("config", r.qnil());
    }

    let layers = r.ary_new();
    for layer in detail.layers {
        let l = r.hash_new();
        let _ = l.aset("diff_id", layer.diff_id);
        let _ = l.aset("blob_digest", layer.blob_digest);
        let _ = l.aset("media_type", layer.media_type);
        let _ = l.aset("compressed_size_bytes", layer.compressed_size_bytes);
        let _ = l.aset("erofs_size_bytes", layer.erofs_size_bytes);
        let _ = l.aset("position", layer.position);
        let _ = layers.push(l);
    }
    let _ = hash.aset("layers", layers);
    hash
}

fn report_to_hash(report: ImagePruneReport) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("image_refs_removed", report.image_refs_removed);
    let _ = hash.aset("manifests_removed", report.manifests_removed);
    let _ = hash.aset("layers_removed", report.layers_removed);
    let _ = hash.aset("fsmeta_removed", report.fsmeta_removed);
    let _ = hash.aset("vmdk_removed", report.vmdk_removed);
    let _ = hash.aset("bytes_reclaimed", report.bytes_reclaimed);
    hash
}

fn get(reference: String) -> Result<RHash, Error> {
    let handle = with_local_backend(async |local| Image::get_local(local, &reference).await)?;
    Ok(handle_to_hash(&handle))
}

fn list() -> Result<RArray, Error> {
    let handles = with_local_backend(async |local| Image::list_local(local).await)?;
    let arr = ruby().ary_new();
    for h in handles.iter() {
        arr.push(handle_to_hash(h))?;
    }
    Ok(arr)
}

fn inspect(reference: String) -> Result<RHash, Error> {
    let detail = with_local_backend(async |local| Image::inspect_local(local, &reference).await)?;
    Ok(detail_to_hash(detail))
}

fn remove(reference: String, force: bool) -> Result<(), Error> {
    with_local_backend(async |local| Image::remove_local(local, &reference, force).await)
}

fn prune() -> Result<RHash, Error> {
    let report = with_local_backend(async |local| Image::prune_local(local).await)?;
    Ok(report_to_hash(report))
}

pub fn define(ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    let class = native.define_class("Image", ruby.class_object())?;
    class.define_singleton_method("get", function!(get, 1))?;
    class.define_singleton_method("list", function!(list, 0))?;
    class.define_singleton_method("inspect", function!(inspect, 1))?;
    class.define_singleton_method("remove", function!(remove, 2))?;
    class.define_singleton_method("prune", function!(prune, 0))?;
    Ok(())
}
