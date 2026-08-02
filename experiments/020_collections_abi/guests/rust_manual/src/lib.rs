//! Leg: Rust, manual ptr+len ABI.
//!
//! The guest owns linear memory and exposes `alloc`/`dealloc`. The host writes
//! bytes in, calls an export with (ptr, len), and frees afterwards. Nothing here
//! is generated — this is the convention written out by hand, and it is the
//! convention every other Rust-targeting toolchain reimplements.
//!
//! Wire formats used by this leg (invented here; that is exactly the point —
//! there is no standard one for core WASM):
//!
//!   u32 array  : raw little-endian u32s, count passed separately.
//!   svec       : u32 count, u32 offsets[count+1], then the UTF-8 blob.
//!                offsets are relative to the start of the svec allocation.
//!   map        : an svec of keys (sorted by key bytes) + a parallel u32 array.
//!
//! Every `*_stats`/`*_sum`/`*_count` export returns a u64 checksum so the host
//! can assert parity against every other leg before timing anything.

use std::alloc::{alloc as rust_alloc, dealloc as rust_dealloc, Layout};
#[cfg(feature = "hashed")]
use std::collections::{HashMap, HashSet};

// ---------------------------------------------------------------------------
// The allocator half of the convention: 2 exports, ~14 lines.
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn alloc(size: usize) -> *mut u8 {
    if size == 0 {
        return 1 as *mut u8; // non-null dangling, matches Rust's own convention
    }
    unsafe { rust_alloc(Layout::from_size_align_unchecked(size, 1)) }
}

#[no_mangle]
pub extern "C" fn dealloc(ptr: *mut u8, size: usize) {
    if size == 0 {
        return;
    }
    unsafe { rust_dealloc(ptr, Layout::from_size_align_unchecked(size, 1)) }
}

// ---------------------------------------------------------------------------
// Shared checksum: FNV-1a over Unicode scalar values, 4 LE bytes each.
// Encoding-independent by construction, so UTF-8 and UTF-16 legs must agree.
// ---------------------------------------------------------------------------

const FNV_OFFSET: u32 = 0x811c_9dc5;
const FNV_PRIME: u32 = 0x0100_0193;

#[inline]
fn fnv_u32(mut h: u32, v: u32) -> u32 {
    let b = v.to_le_bytes();
    let mut i = 0;
    while i < 4 {
        h ^= b[i] as u32;
        h = h.wrapping_mul(FNV_PRIME);
        i += 1;
    }
    h
}

#[inline]
fn pack(count: u32, hash: u32) -> u64 {
    ((count as u64) << 32) | (hash as u64)
}

// ---------------------------------------------------------------------------
// STRINGS
// ---------------------------------------------------------------------------

/// `(ptr, len)` in, packed `(code_point_count << 32 | fnv)` out.
/// The host must have written valid UTF-8 there. Nothing checks that it did.
#[no_mangle]
pub extern "C" fn str_stats(ptr: *const u8, len: usize) -> u64 {
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    let s = unsafe { std::str::from_utf8_unchecked(bytes) };
    let mut h = FNV_OFFSET;
    let mut n = 0u32;
    for c in s.chars() {
        h = fnv_u32(h, c as u32);
        n += 1;
    }
    pack(n, h)
}

/// Returning a string is where the ptr+len convention runs out of room: WASM
/// core can return only one value per pre-multi-value ABI, so you either pack
/// two u32s into an i64 (this), or write to a caller-supplied scratch slot
/// (`str_upper_ascii_retptr`, below — what wasm-bindgen generates).
///
/// Ownership: the returned buffer is guest-owned and leaked until the host
/// calls `dealloc(ptr, len)`. There is no other protocol.
#[no_mangle]
pub extern "C" fn str_upper_ascii_packed(ptr: *const u8, len: usize) -> u64 {
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    let mut out: Vec<u8> = bytes.iter().map(|b| b.to_ascii_uppercase()).collect();
    out.shrink_to_fit();
    let p = out.as_mut_ptr() as u32;
    let l = out.len() as u32;
    std::mem::forget(out);
    ((p as u64) << 32) | (l as u64)
}

/// The other half of the same problem: caller passes an 8-byte scratch slot and
/// the guest writes `[ptr: u32, len: u32]` into it. Identical information, one
/// extra memory round-trip, and it needs the host to have allocated the slot.
#[no_mangle]
pub extern "C" fn str_upper_ascii_retptr(ret: *mut u32, ptr: *const u8, len: usize) {
    let packed = str_upper_ascii_packed(ptr, len);
    unsafe {
        *ret = (packed >> 32) as u32;
        *ret.add(1) = packed as u32;
    }
}

// ---------------------------------------------------------------------------
// LISTS
// ---------------------------------------------------------------------------

/// Homogeneous numeric list: the good case. The host's bytes are already the
/// guest's representation, so "marshalling" is one `copy_from_slice`.
#[no_mangle]
pub extern "C" fn list_sum_u32(ptr: *const u32, len: usize) -> u64 {
    let xs = unsafe { std::slice::from_raw_parts(ptr, len) };
    let mut h = FNV_OFFSET;
    let mut acc = 0u64;
    for &x in xs {
        acc = acc.wrapping_add(x as u64);
        h = fnv_u32(h, x);
    }
    acc ^ (h as u64) << 32
}

// ---------------------------------------------------------------------------
// svec decoding — shared by maps
// ---------------------------------------------------------------------------

/// # Safety
/// `base` must point at a well-formed svec written by the host.
unsafe fn svec_parts<'a>(base: *const u8) -> (usize, &'a [u32], &'a [u8]) {
    let hdr = base as *const u32;
    let count = *hdr as usize;
    let offsets = std::slice::from_raw_parts(hdr.add(1), count + 1);
    let blob_start = 4 + 4 * (count + 1);
    let blob_len = offsets[count] as usize - blob_start;
    let blob = std::slice::from_raw_parts(base.add(blob_start), blob_len);
    (count, offsets, blob)
}

#[inline]
unsafe fn svec_get<'a>(offsets: &[u32], blob: &'a [u8], i: usize) -> &'a str {
    let blob_start = 4 + 4 * (offsets.len()); // offsets.len() == count + 1
    let a = offsets[i] as usize - blob_start;
    let b = offsets[i + 1] as usize - blob_start;
    std::str::from_utf8_unchecked(&blob[a..b])
}

// ---------------------------------------------------------------------------
// MAPS — there is no WASM concept, so pick one of these three.
// ---------------------------------------------------------------------------

/// Option A: serialize to sorted key/value pairs, binary-search in the guest.
/// No build cost, O(log n) per probe, no allocation at all.
#[no_mangle]
pub extern "C" fn map_lookup_sorted(keys: *const u8, vals: *const u32, probes: *const u8) -> u64 {
    unsafe {
        let (n, koff, kblob) = svec_parts(keys);
        let values = std::slice::from_raw_parts(vals, n);
        let (m, poff, pblob) = svec_parts(probes);
        let mut acc = 0u64;
        let mut hits = 0u32;
        for i in 0..m {
            let probe = svec_get(poff, pblob, i);
            let (mut lo, mut hi) = (0usize, n);
            while lo < hi {
                let mid = (lo + hi) / 2;
                if svec_get(koff, kblob, mid) < probe {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if lo < n && svec_get(koff, kblob, lo) == probe {
                acc = acc.wrapping_add(values[lo] as u64);
                hits += 1;
            }
        }
        acc ^ ((hits as u64) << 40)
    }
}

/// Option B: build a real `HashMap` in linear memory on every call. Pays a full
/// build for one batch of probes — the shape you get if you naively hand the
/// guest a map-shaped blob and let it "just use a HashMap".
#[cfg(feature = "hashed")]
#[no_mangle]
pub extern "C" fn map_lookup_hash(keys: *const u8, vals: *const u32, probes: *const u8) -> u64 {
    unsafe {
        let (n, koff, kblob) = svec_parts(keys);
        let values = std::slice::from_raw_parts(vals, n);
        let mut map: HashMap<&str, u32> = HashMap::with_capacity(n);
        for i in 0..n {
            map.insert(svec_get(koff, kblob, i), values[i]);
        }
        let (m, poff, pblob) = svec_parts(probes);
        let mut acc = 0u64;
        let mut hits = 0u32;
        for i in 0..m {
            if let Some(&v) = map.get(svec_get(poff, pblob, i)) {
                acc = acc.wrapping_add(v as u64);
                hits += 1;
            }
        }
        acc ^ ((hits as u64) << 40)
    }
}

// Option C: build once, keep the map guest-side behind an integer handle, probe
// many times. The guest becomes stateful; the handle is the guest-side mirror
// of the `externref` trick.
#[cfg(feature = "hashed")]
static mut MAPS: Vec<HashMap<String, u32>> = Vec::new();

#[cfg(feature = "hashed")]
#[no_mangle]
pub extern "C" fn map_build(keys: *const u8, vals: *const u32) -> u32 {
    unsafe {
        let (n, koff, kblob) = svec_parts(keys);
        let values = std::slice::from_raw_parts(vals, n);
        let mut map: HashMap<String, u32> = HashMap::with_capacity(n);
        for i in 0..n {
            map.insert(svec_get(koff, kblob, i).to_string(), values[i]);
        }
        let maps = &mut *std::ptr::addr_of_mut!(MAPS);
        maps.push(map);
        (maps.len() - 1) as u32
    }
}

#[cfg(feature = "hashed")]
#[no_mangle]
pub extern "C" fn map_query(handle: u32, probes: *const u8) -> u64 {
    unsafe {
        let maps = &*std::ptr::addr_of!(MAPS);
        let map = &maps[handle as usize];
        let (m, poff, pblob) = svec_parts(probes);
        let mut acc = 0u64;
        let mut hits = 0u32;
        for i in 0..m {
            if let Some(&v) = map.get(svec_get(poff, pblob, i)) {
                acc = acc.wrapping_add(v as u64);
                hits += 1;
            }
        }
        acc ^ ((hits as u64) << 40)
    }
}

// ---------------------------------------------------------------------------
// SETS — maps minus values, plus the bitset case.
// ---------------------------------------------------------------------------

/// A set over a small integer domain is a `u64` array. `1 << (x & 63)` and
/// `i64.and` are single instructions; WASM has had them since MVP.
#[no_mangle]
pub extern "C" fn set_count_bitset(
    words: *const u64,
    nwords: usize,
    probes: *const u32,
    m: usize,
) -> u64 {
    let w = unsafe { std::slice::from_raw_parts(words, nwords) };
    let p = unsafe { std::slice::from_raw_parts(probes, m) };
    let mut hits = 0u64;
    for &x in p {
        let i = (x >> 6) as usize;
        if i < nwords && (w[i] >> (x & 63)) & 1 == 1 {
            hits += 1;
        }
    }
    hits
}

/// Sorted u32 array + binary search. Domain-independent, 4 bytes per member.
#[no_mangle]
pub extern "C" fn set_count_sorted(
    members: *const u32,
    n: usize,
    probes: *const u32,
    m: usize,
) -> u64 {
    let s = unsafe { std::slice::from_raw_parts(members, n) };
    let p = unsafe { std::slice::from_raw_parts(probes, m) };
    let mut hits = 0u64;
    for &x in p {
        if s.binary_search(&x).is_ok() {
            hits += 1;
        }
    }
    hits
}

/// `HashSet` built per call — the "just use the stdlib" shape.
#[cfg(feature = "hashed")]
#[no_mangle]
pub extern "C" fn set_count_hash(
    members: *const u32,
    n: usize,
    probes: *const u32,
    m: usize,
) -> u64 {
    let s = unsafe { std::slice::from_raw_parts(members, n) };
    let p = unsafe { std::slice::from_raw_parts(probes, m) };
    let set: HashSet<u32> = s.iter().copied().collect();
    let mut hits = 0u64;
    for &x in p {
        if set.contains(&x) {
            hits += 1;
        }
    }
    hits
}
