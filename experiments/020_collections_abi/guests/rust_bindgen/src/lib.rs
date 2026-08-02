//! 020 leg 3 — Rust + wasm-bindgen.
//!
//! Compare this file with `../rust_manual/src/lib.rs`. The bodies are the same;
//! the signatures are ordinary Rust types. wasm-bindgen generates the ptr+len
//! plumbing the manual leg writes by hand — an `alloc`/`free` pair
//! (`__wbindgen_malloc`/`__wbindgen_free`), a *multi-value shim* wrapping
//! rustc's scratch-return-pointer ABI, and a JS module full of encode/decode
//! helpers. `make disasm` dumps all of it.
//!
//! The host is Node here, not wasmtime: wasm-bindgen's output is a JS module.
//! That is a real constraint of the strategy, not a harness choice.

use wasm_bindgen::prelude::*;

const FNV_OFFSET: u32 = 0x811c_9dc5;
const FNV_PRIME: u32 = 0x0100_0193;

#[inline]
fn fnv_u32(mut h: u32, v: u32) -> u32 {
    for b in v.to_le_bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(FNV_PRIME);
    }
    h
}

#[wasm_bindgen]
pub fn str_stats(s: &str) -> u64 {
    let mut h = FNV_OFFSET;
    let mut n = 0u32;
    for c in s.chars() {
        h = fnv_u32(h, c as u32);
        n += 1;
    }
    ((n as u64) << 32) | (h as u64)
}

/// Same signature, empty body: isolates the generated glue's fixed per-call
/// cost from the work.
#[wasm_bindgen]
pub fn noop_str(s: &str) -> u64 {
    s.len() as u64
}

#[wasm_bindgen]
pub fn list_sum_u32(xs: &[u32]) -> u64 {
    let mut h = FNV_OFFSET;
    let mut acc = 0u64;
    for &x in xs {
        acc = acc.wrapping_add(x as u64);
        h = fnv_u32(h, x);
    }
    acc ^ ((h as u64) << 32)
}

#[wasm_bindgen]
pub fn noop_list_u32(xs: &[u32]) -> u64 {
    xs.len() as u64
}

/// `Vec<String>` is where wasm-bindgen's generated glue gets expensive, and it
/// does NOT do what a reader of the manual leg would guess. Verified in
/// `pkg/collections_bindgen.js`: `passArrayJsValueToWasm0` puts each JS string
/// into the **externref table** and writes the table index into linear memory.
/// The UTF-8 encode happens later and lazily — the guest calls back out through
/// the `__wbindgen_string_get` import once per element. So a `Vec<String>`
/// argument is 2n boundary crossings plus n externref-table slots, not one bulk
/// copy.
#[wasm_bindgen]
pub fn map_lookup_sorted(keys: Vec<String>, vals: &[u32], probes: Vec<String>) -> u64 {
    let mut acc = 0u64;
    let mut hits = 0u32;
    for p in &probes {
        if let Ok(i) = keys.binary_search_by(|k| k.as_str().cmp(p.as_str())) {
            acc = acc.wrapping_add(vals[i] as u64);
            hits += 1;
        }
    }
    acc ^ ((hits as u64) << 40)
}

#[wasm_bindgen]
pub fn noop_map(keys: Vec<String>, _vals: &[u32], probes: Vec<String>) -> u64 {
    (keys.len() + probes.len()) as u64
}

#[wasm_bindgen]
pub fn set_count_sorted(members: &[u32], probes: &[u32]) -> u64 {
    probes
        .iter()
        .filter(|p| members.binary_search(p).is_ok())
        .count() as u64
}

#[wasm_bindgen]
pub fn set_count_bitset(words: &[u64], probes: &[u32]) -> u64 {
    let mut hits = 0u64;
    for &x in probes {
        let i = (x >> 6) as usize;
        if i < words.len() && (words[i] >> (x & 63)) & 1 == 1 {
            hits += 1;
        }
    }
    hits
}

#[wasm_bindgen]
pub fn noop_set(members: &[u32], probes: &[u32]) -> u64 {
    (members.len() + probes.len()) as u64
}

/// Returning a `String` — the case that shows both answers to "how does a WASM
/// function return two numbers?" in one binary. rustc lowers this to
/// `(param i32 i32 i32)` with no result: the first i32 is a caller-supplied
/// return area. wasm-bindgen then post-processes the module and injects
/// `"str_upper_ascii multivalue shim"`, type `(param i32 i32) (result i32 i32)`,
/// so JS receives a real two-element return. Verified with `wasm-tools print`;
/// see the README's strings section.
#[wasm_bindgen]
pub fn str_upper_ascii(s: &str) -> String {
    s.to_ascii_uppercase()
}
