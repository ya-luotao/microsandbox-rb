//! Snapshot management: `Microsandbox::Native::Snapshot`.
//!
//! Snapshots capture a stopped sandbox's disk state into a portable artifact
//! that a later `Sandbox.create(from_snapshot:)` can boot from. Exposed as
//! singleton functions returning plain Hashes/Arrays (shaped into value objects
//! by the Ruby layer) — there is no long-lived handle to own.
//!
//! v0.6.7 descriptor contract: an artifact is identified by its own `name`
//! (`Snapshot::builder(name).from_sandbox(src)`), lives at `dest_dir/<name>`,
//! and its descriptor file is `snapshot.json`. `manifest.json` artifacts from
//! v0.6.6 are auto-migrated by the core on first backend connect.

use std::path::{Path, PathBuf};

use magnus::{function, prelude::*, Error, RArray, RHash, RModule, Ruby};
use microsandbox::snapshot::{
    SaveOpts, Snapshot, SnapshotFormat, SnapshotHandle, SnapshotScope, SnapshotVerifyReport,
    UpperVerifyStatus,
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

fn scope_str(scope: SnapshotScope) -> &'static str {
    match scope {
        SnapshotScope::Disk => "disk",
        SnapshotScope::Resumable => "resumable",
    }
}

/// Parse a manifest's RFC 3339 `created_at` into epoch-ms (nil if unparseable).
fn created_at_ms(rfc3339: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(rfc3339)
        .ok()
        .map(|dt| dt.timestamp_millis())
}

/// Convert a fully-opened `Snapshot` into the `SnapshotInfo` Hash. Unlike a
/// `SnapshotHandle` (a lightweight index row), an opened snapshot carries the
/// full descriptor, so this is the richest shape — `create`/`open`/`list_dir`
/// and the `SandboxHandle#snapshot` shortcut all funnel here. `format`/
/// `fstype`/`size_bytes` are nil for checkpoint-state snapshots, and the
/// `checkpoint_*` keys are nil for file-state ones — the two state families
/// are disjoint by contract.
pub(crate) fn snapshot_to_hash(snap: &Snapshot) -> RHash {
    let m = snap.manifest();
    let state = snap.state();
    let file = state.as_file();
    let checkpoint = state.as_checkpoint();
    let hash = ruby().hash_new();
    let _ = hash.aset("digest", snap.digest().to_string());
    let _ = hash.aset("path", snap.path().to_string_lossy().into_owned());
    let _ = hash.aset("size_bytes", snap.size_bytes());
    let _ = hash.aset("scope", scope_str(m.scope));
    let _ = hash.aset("state_kind", state.kind());
    let _ = hash.aset("image_ref", m.image.reference.clone());
    let _ = hash.aset("image_manifest_digest", m.image.manifest_digest.clone());
    let _ = hash.aset("format", file.map(|f| format_str(f.format)));
    let _ = hash.aset("fstype", file.map(|f| f.fstype.clone()));
    let _ = hash.aset("checkpoint_id", checkpoint.map(|c| c.checkpoint_id.clone()));
    let _ = hash.aset(
        "checkpoint_manifest_digest",
        checkpoint.map(|c| c.manifest.clone()),
    );
    let _ = hash.aset("parent_digest", m.parent.clone());
    let _ = hash.aset("created_at_ms", created_at_ms(&m.created_at));
    let _ = hash.aset("source_sandbox", m.source_sandbox.clone());
    let labels = ruby().hash_new();
    for (k, v) in &m.labels {
        let _ = labels.aset(k.as_str(), v.as_str());
    }
    let _ = hash.aset("labels", labels);
    hash
}

/// Create a snapshot artifact named `name` from a stopped sandbox. `opts`:
/// from_sandbox (required), dest_dir, labels, force, record_integrity,
/// resumable. Returns the full SnapshotInfo Hash.
fn create(name: String, opts: RHash) -> Result<RHash, Error> {
    let mut b = Snapshot::builder(name);
    match conv::opt_string(opts, "from_sandbox")? {
        Some(src) => b = b.from_sandbox(src),
        None => {
            return Err(error::base_error(
                "snapshot create needs from_sandbox: (the source sandbox name)",
            ));
        }
    }
    if let Some(dir) = conv::opt_string(opts, "dest_dir")? {
        b = b.dest_dir(PathBuf::from(dir));
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
    if conv::opt_bool(opts, "resumable")? {
        b = b.resumable();
    }

    let snap = block_on(b.create()).map_err(error::to_ruby)?;
    Ok(snapshot_to_hash(&snap))
}

/// Open an existing snapshot artifact by bare name or path. Cheap metadata
/// validation only (does not read the upper file). Returns a full SnapshotInfo
/// Hash — the only way to inspect an artifact addressed by path (`get`/`list`
/// read the local index, which path-addressed artifacts are absent from).
fn open(path_or_name: String) -> Result<RHash, Error> {
    let snap = block_on(Snapshot::open(&path_or_name)).map_err(error::to_ruby)?;
    Ok(snapshot_to_hash(&snap))
}

/// Walk `dir` and parse each subdirectory's `snapshot.json` without touching
/// the local index — for enumerating external/un-imported snapshot collections.
fn list_dir(dir: String) -> Result<RArray, Error> {
    let snaps = block_on(Snapshot::list_dir(Path::new(&dir))).map_err(error::to_ruby)?;
    let arr = ruby().ary_new();
    for snap in &snaps {
        arr.push(snapshot_to_hash(snap))?;
    }
    Ok(arr)
}

/// Rebuild the local snapshot index from `dir` (defaults to the configured
/// snapshots directory). Returns the number of indexed snapshots — the repair
/// for index drift or out-of-band imports that `get`/`list` can't see.
fn reindex(dir: Option<String>) -> Result<u64, Error> {
    let dir: PathBuf = match dir {
        Some(d) => PathBuf::from(d),
        None => microsandbox::default_backend()
            .as_local()
            .map(|l| l.snapshots_dir())
            .unwrap_or_else(|| PathBuf::from(".")),
    };
    let n = block_on(Snapshot::reindex(&dir)).map_err(error::to_ruby)?;
    Ok(n as u64)
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
/// {digest, path, upper_status, upper_algorithm, upper_digest}. Schema-1
/// descriptors always record integrity, so the status is always "verified"
/// on success (mismatches raise SnapshotIntegrityError instead).
fn verify(name_or_path: String) -> Result<RHash, Error> {
    let snap = block_on(Snapshot::open(&name_or_path)).map_err(error::to_ruby)?;
    let report = block_on(snap.verify()).map_err(error::to_ruby)?;
    Ok(verify_report_to_hash(&report))
}

/// Bundle a snapshot into a `.tar.zst` (or plain `.tar`) archive. `opts`:
/// with_parents, with_image, plain_tar.
fn save(name_or_path: String, out_path: String, opts: RHash) -> Result<(), Error> {
    let save_opts = SaveOpts {
        with_parents: conv::opt_bool(opts, "with_parents")?,
        with_image: conv::opt_bool(opts, "with_image")?,
        plain_tar: conv::opt_bool(opts, "plain_tar")?,
    };
    block_on(Snapshot::save(
        &name_or_path,
        std::path::Path::new(&out_path),
        save_opts,
    ))
    .map_err(error::to_ruby)
}

/// Unpack a snapshot archive into the snapshots dir. Returns the loaded
/// snapshot's metadata hash. `dest` is an optional explicit directory.
fn load(archive_path: String, dest: Option<String>) -> Result<RHash, Error> {
    let dest_path = dest.map(PathBuf::from);
    let handle = block_on(Snapshot::load(
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
    let _ = hash.aset("scope", scope_str(handle.scope()));
    let _ = hash.aset("state_kind", handle.state_kind().to_string());
    let _ = hash.aset("image_ref", handle.image_ref().to_string());
    let _ = hash.aset("format", handle.format().map(format_str));
    let _ = hash.aset("fstype", handle.fstype().map(str::to_string));
    let _ = hash.aset(
        "checkpoint_manifest_digest",
        handle.checkpoint_manifest_digest().map(str::to_string),
    );
    let _ = hash.aset("size_bytes", handle.size_bytes());
    let _ = hash.aset("locality", handle.locality().to_string());
    let _ = hash.aset("availability", handle.availability().to_string());
    let _ = hash.aset("migration_state", handle.migration_state().to_string());
    let _ = hash.aset(
        "migration_error_code",
        handle.migration_error_code().map(str::to_string),
    );
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
    class.define_singleton_method("open", function!(open, 1))?;
    class.define_singleton_method("get", function!(get, 1))?;
    class.define_singleton_method("list", function!(list, 0))?;
    class.define_singleton_method("list_dir", function!(list_dir, 1))?;
    class.define_singleton_method("reindex", function!(reindex, 1))?;
    class.define_singleton_method("remove", function!(remove, 2))?;
    class.define_singleton_method("verify", function!(verify, 1))?;
    class.define_singleton_method("save", function!(save, 3))?;
    class.define_singleton_method("load", function!(load, 2))?;
    Ok(())
}
