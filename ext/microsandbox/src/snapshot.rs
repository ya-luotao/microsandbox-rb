//! Snapshot management: `Microsandbox::Native::Snapshot`.
//!
//! Snapshots capture a stopped sandbox's upper layer into a portable artifact
//! that a later `Sandbox.create(from_snapshot:)` can boot from. Exposed as
//! singleton functions returning plain Hashes/Arrays (shaped into value objects
//! by the Ruby layer) — there is no long-lived handle to own.

use std::path::PathBuf;

use magnus::{function, prelude::*, Error, RArray, RHash, RModule, Ruby};
use microsandbox::snapshot::{
    ExportOpts, Snapshot, SnapshotDestination, SnapshotFormat, SnapshotHandle,
    SnapshotVerifyReport, UpperVerifyStatus,
};

use crate::conv;
use crate::error;
use crate::runtime::{block_on, ruby};

fn format_str(format: SnapshotFormat) -> &'static str {
    match format {
        SnapshotFormat::Raw => "raw",
        SnapshotFormat::Qcow2 => "qcow2",
    }
}

/// Create a snapshot of a stopped sandbox. `opts`: name | path (destination),
/// labels, force, record_integrity. Returns {digest, path, size_bytes}.
fn create(source_sandbox: String, opts: RHash) -> Result<RHash, Error> {
    let mut b = Snapshot::builder(source_sandbox);
    if let Some(name) = conv::opt_string(opts, "name")? {
        b = b.destination(SnapshotDestination::Name(name));
    } else if let Some(path) = conv::opt_string(opts, "path")? {
        b = b.destination(SnapshotDestination::Path(PathBuf::from(path)));
    } else {
        return Err(error::base_error(
            "snapshot create needs a destination: pass name: or path:",
        ));
    }
    for (k, v) in conv::opt_string_map(opts, "labels")? {
        b = b.label(k, v);
    }
    if conv::opt_bool(opts, "force")? {
        b = b.force();
    }
    if conv::opt_bool(opts, "record_integrity")? {
        b = b.record_integrity();
    }

    let snap = block_on(b.create()).map_err(error::to_ruby)?;
    let hash = ruby().hash_new();
    hash.aset("digest", snap.digest().to_string())?;
    hash.aset("path", snap.path().to_string_lossy().into_owned())?;
    hash.aset("size_bytes", snap.size_bytes())?;
    Ok(hash)
}

/// Metadata for one snapshot by name or digest.
fn get(name_or_digest: String) -> Result<RHash, Error> {
    let handle = block_on(Snapshot::get(&name_or_digest)).map_err(error::to_ruby)?;
    Ok(handle_to_hash(&handle))
}

/// All snapshots as metadata hashes.
fn list() -> Result<RArray, Error> {
    let handles = block_on(Snapshot::list()).map_err(error::to_ruby)?;
    let arr = ruby().ary_new();
    for h in &handles {
        arr.push(handle_to_hash(h))?;
    }
    Ok(arr)
}

/// Remove a snapshot artifact by name or path.
fn remove(name_or_path: String, force: bool) -> Result<(), Error> {
    block_on(Snapshot::remove(&name_or_path, force)).map_err(error::to_ruby)
}

/// Verify a snapshot's recorded upper-layer integrity. Returns
/// {digest, path, upper_status, upper_algorithm?, upper_digest?}.
fn verify(name_or_path: String) -> Result<RHash, Error> {
    let snap = block_on(Snapshot::open(&name_or_path)).map_err(error::to_ruby)?;
    let report = block_on(snap.verify()).map_err(error::to_ruby)?;
    Ok(verify_report_to_hash(&report))
}

/// Bundle a snapshot into a `.tar.zst` (or plain `.tar`) archive. `opts`:
/// with_parents, with_image, plain_tar.
fn export(name_or_path: String, out_path: String, opts: RHash) -> Result<(), Error> {
    let export_opts = ExportOpts {
        with_parents: conv::opt_bool(opts, "with_parents")?,
        with_image: conv::opt_bool(opts, "with_image")?,
        plain_tar: conv::opt_bool(opts, "plain_tar")?,
    };
    block_on(Snapshot::export(
        &name_or_path,
        std::path::Path::new(&out_path),
        export_opts,
    ))
    .map_err(error::to_ruby)
}

/// Unpack a snapshot archive into the snapshots dir. Returns the imported
/// snapshot's metadata hash. `dest` is an optional explicit directory.
fn import(archive_path: String, dest: Option<String>) -> Result<RHash, Error> {
    let dest_path = dest.map(PathBuf::from);
    let handle = block_on(Snapshot::import(
        std::path::Path::new(&archive_path),
        dest_path.as_deref(),
    ))
    .map_err(error::to_ruby)?;
    Ok(handle_to_hash(&handle))
}

fn handle_to_hash(handle: &SnapshotHandle) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("digest", handle.digest().to_string());
    let _ = hash.aset("name", handle.name().map(str::to_string));
    let _ = hash.aset("parent_digest", handle.parent_digest().map(str::to_string));
    let _ = hash.aset("image_ref", handle.image_ref().to_string());
    let _ = hash.aset("format", format_str(handle.format()));
    let _ = hash.aset("size_bytes", handle.size_bytes());
    let _ = hash.aset("path", handle.path().to_string_lossy().into_owned());
    let _ = hash.aset(
        "created_at_ms",
        handle.created_at().and_utc().timestamp_millis(),
    );
    hash
}

fn verify_report_to_hash(report: &SnapshotVerifyReport) -> RHash {
    let hash = ruby().hash_new();
    let _ = hash.aset("digest", report.digest.clone());
    let _ = hash.aset("path", report.path.to_string_lossy().into_owned());
    match &report.upper {
        UpperVerifyStatus::NotRecorded => {
            let _ = hash.aset("upper_status", "not_recorded");
        }
        UpperVerifyStatus::Verified { algorithm, digest } => {
            let _ = hash.aset("upper_status", "verified");
            let _ = hash.aset("upper_algorithm", algorithm.clone());
            let _ = hash.aset("upper_digest", digest.clone());
        }
    }
    hash
}

pub fn define(ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    let class = native.define_class("Snapshot", ruby.class_object())?;
    class.define_singleton_method("create", function!(create, 2))?;
    class.define_singleton_method("get", function!(get, 1))?;
    class.define_singleton_method("list", function!(list, 0))?;
    class.define_singleton_method("remove", function!(remove, 2))?;
    class.define_singleton_method("verify", function!(verify, 1))?;
    class.define_singleton_method("export", function!(export, 3))?;
    class.define_singleton_method("import", function!(import, 2))?;
    Ok(())
}
