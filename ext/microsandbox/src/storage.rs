//! Storage diagnosis and recovery (runtime v0.7): `Microsandbox::Native::Storage`.
//!
//! Runtime v0.7 moves a sandbox's disks into a protected storage layout. On
//! Linux an older sandbox migrates on its next start; on macOS (and for
//! ambiguous or damaged legacy metadata) it needs an explicit recovery while
//! the sandbox is stopped. Both entry points are JSON bridges over the core's
//! own wire types, like the official SDKs' (`sdk/ruby/ext/.../storage.rs`):
//! the Ruby layer builds the request and shapes the report.

use magnus::{function, prelude::*, Error, RModule, Ruby};
use microsandbox::sandbox::StorageRecoveryOptions;

use crate::error;
use crate::runtime::block_on;

/// Inspect storage without starting, stopping, repairing or migrating
/// anything. `config_json` is `{"home": …}` (optional); `scope_json` is
/// `"all"` or `{"named": [names]}`. Returns the diagnosis as JSON.
fn diagnose_json(config_json: String, scope_json: String) -> Result<String, Error> {
    block_on(async move {
        microsandbox::setup::binding_diagnose_storage(&config_json, &scope_json).await
    })?
    .map_err(error::to_ruby)
}

/// Import or resume a stopped sandbox's storage without booting it.
/// `options_json` is `{"selections": [{disk_id, candidate_id}],
/// "accept_selected_view": bool, "legacy_writers_stopped": bool}`. Returns
/// `{"name", "ready", "originals_retained"}` as JSON.
fn recover_json(name: String, options_json: String) -> Result<String, Error> {
    let options: StorageRecoveryOptions = serde_json::from_str(&options_json)
        .map_err(|e| error::base_error(format!("invalid storage recovery options: {e}")))?;
    let recovery = block_on(microsandbox::Sandbox::recover_storage(&name, options))?
        .map_err(error::to_ruby)?;
    serde_json::to_string(&recovery)
        .map_err(|e| error::base_error(format!("cannot encode the storage recovery result: {e}")))
}

pub fn define(_ruby: &Ruby, native: &RModule) -> Result<(), Error> {
    let module = native.define_module("Storage")?;
    module.define_singleton_method("diagnose_json", function!(diagnose_json, 2))?;
    module.define_singleton_method("recover_json", function!(recover_json, 2))?;
    Ok(())
}
