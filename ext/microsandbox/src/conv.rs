//! Helpers for reading a Ruby options `Hash` (string keys) into Rust values.
//!
//! The Ruby layer normalizes keyword arguments into a string-keyed Hash before
//! handing it to the native layer, so lookups here are by `&str`.

use std::collections::HashMap;

use magnus::{value::ReprValue, Error, RArray, RHash, TryConvert, Value};

/// Fetch a non-nil value for `key`, if present.
fn get(hash: RHash, key: &str) -> Option<Value> {
    match hash.get(key) {
        Some(v) if !v.is_nil() => Some(v),
        _ => None,
    }
}

/// Generic typed fetch: `None` if the key is absent/nil, else converted.
pub fn opt<T: TryConvert>(hash: RHash, key: &str) -> Result<Option<T>, Error> {
    match get(hash, key) {
        Some(v) => Ok(Some(T::try_convert(v)?)),
        None => Ok(None),
    }
}

pub fn opt_string(hash: RHash, key: &str) -> Result<Option<String>, Error> {
    opt(hash, key)
}

pub fn opt_bool(hash: RHash, key: &str) -> Result<bool, Error> {
    Ok(opt::<bool>(hash, key)?.unwrap_or(false))
}

pub fn opt_u8(hash: RHash, key: &str) -> Result<Option<u8>, Error> {
    opt(hash, key)
}

pub fn opt_u32(hash: RHash, key: &str) -> Result<Option<u32>, Error> {
    opt(hash, key)
}

pub fn opt_f64(hash: RHash, key: &str) -> Result<Option<f64>, Error> {
    opt(hash, key)
}

/// String→String map (e.g. `env`, `labels`, `scripts`). Empty if absent.
pub fn opt_string_map(hash: RHash, key: &str) -> Result<Vec<(String, String)>, Error> {
    match get(hash, key) {
        Some(v) => {
            let map = HashMap::<String, String>::try_convert(v)?;
            Ok(map.into_iter().collect())
        }
        None => Ok(Vec::new()),
    }
}

/// Array of strings (e.g. `entrypoint`, `args`). Empty if absent.
pub fn opt_string_vec(hash: RHash, key: &str) -> Result<Vec<String>, Error> {
    match get(hash, key) {
        Some(v) => Ok(Vec::<String>::try_convert(v)?),
        None => Ok(Vec::new()),
    }
}

/// Array of `Hash`es (e.g. `patches`, custom-policy `rules`). Empty if absent.
///
/// `RHash` is a GC-managed handle and so cannot be collected via the blanket
/// `Vec<T: TryConvert>` path; we walk the `Array` and convert each element.
pub fn opt_hash_vec(hash: RHash, key: &str) -> Result<Vec<RHash>, Error> {
    match get(hash, key) {
        Some(v) => {
            let arr = RArray::try_convert(v)?;
            let mut out = Vec::with_capacity(arr.len());
            for i in 0..arr.len() {
                out.push(arr.entry::<RHash>(i as isize)?);
            }
            Ok(out)
        }
        None => Ok(Vec::new()),
    }
}

/// `u16`→`u16` port map (host→guest TCP). Empty if absent.
pub fn opt_port_map(hash: RHash, key: &str) -> Result<Vec<(u16, u16)>, Error> {
    match get(hash, key) {
        Some(v) => {
            let map = HashMap::<u16, u16>::try_convert(v)?;
            Ok(map.into_iter().collect())
        }
        None => Ok(Vec::new()),
    }
}
