//! 020 leg 5 — Component Model / WIT.
//!
//! Note what is *absent* from this file: no `alloc`, no `dealloc`, no ptr+len,
//! no wire format, no offset arithmetic. The signatures say `String`,
//! `Vec<u32>`, `Vec<(String, u32)>` and the canonical ABI does the lowering.
//! `wit-bindgen` emits `cabi_realloc` and the lifting/lowering shims; the host
//! never learns a convention this crate invented, because this crate invented
//! none.
//!
//! The `noop_*` exports exist so the harness can separate the canonical ABI's
//! copy (which happens *inside* the call, not before it) from the compute.

wit_bindgen::generate!({
    world: "collections",
    path: "wit",
});

struct C;

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

impl Guest for C {
    fn str_stats(s: String) -> u64 {
        let mut h = FNV_OFFSET;
        let mut n = 0u32;
        for c in s.chars() {
            h = fnv_u32(h, c as u32);
            n += 1;
        }
        ((n as u64) << 32) | (h as u64)
    }

    fn noop_str(s: String) -> u64 {
        s.len() as u64
    }

    fn list_sum_u32(xs: Vec<u32>) -> u64 {
        let mut h = FNV_OFFSET;
        let mut acc = 0u64;
        for &x in &xs {
            acc = acc.wrapping_add(x as u64);
            h = fnv_u32(h, x);
        }
        acc ^ ((h as u64) << 32)
    }

    fn noop_list_u32(xs: Vec<u32>) -> u64 {
        xs.len() as u64
    }

    fn map_lookup_sorted(entries: Vec<(String, u32)>, probes: Vec<String>) -> u64 {
        let mut acc = 0u64;
        let mut hits = 0u32;
        for p in &probes {
            if let Ok(i) = entries.binary_search_by(|e| e.0.as_str().cmp(p.as_str())) {
                acc = acc.wrapping_add(entries[i].1 as u64);
                hits += 1;
            }
        }
        acc ^ ((hits as u64) << 40)
    }

    fn noop_map(entries: Vec<(String, u32)>, probes: Vec<String>) -> u64 {
        (entries.len() + probes.len()) as u64
    }

    fn set_count_sorted(members: Vec<u32>, probes: Vec<u32>) -> u64 {
        probes
            .iter()
            .filter(|p| members.binary_search(p).is_ok())
            .count() as u64
    }

    fn set_count_bitset(words: Vec<u64>, probes: Vec<u32>) -> u64 {
        let mut hits = 0u64;
        for &x in &probes {
            let i = (x >> 6) as usize;
            if i < words.len() && (words[i] >> (x & 63)) & 1 == 1 {
                hits += 1;
            }
        }
        hits
    }

    fn noop_set(members: Vec<u32>, probes: Vec<u32>) -> u64 {
        (members.len() + probes.len()) as u64
    }

    fn str_upper_ascii(s: String) -> String {
        s.to_ascii_uppercase()
    }
}

export!(C);
