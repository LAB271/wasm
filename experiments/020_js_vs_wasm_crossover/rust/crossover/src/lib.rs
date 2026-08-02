//! Experiment 020 — JS-vs-WASM crossover functions.
//!
//! `no_std`, no allocator crate: everything below is either a scalar function
//! (Axis 1 rung 1) or a "read N somethings out of linear memory, write a
//! result" batch function (rungs 2-5 + the Axis 2 granularity sweep). Callers
//! (JS) request scratch space with `alloc`, write their data into it via the
//! exported `memory`, then call the batch fn with (ptr, len) pairs.
//!
//! `unsafe` appears ONLY at the FFI boundary, to reinterpret a raw
//! (ptr, len) pair handed in from JS as a `&[T]`/`&mut [T]` — that is
//! unavoidable for reading linear memory from outside the module, not a
//! shortcut to dodge bounds checks. Everything after that reinterpretation
//! uses ordinary safe indexing/iterators unless a function is explicitly
//! named `_unchecked`, which exists specifically to *measure* what
//! `get_unchecked` buys you over safe indexing (see README "bounds checks").
#![cfg_attr(target_arch = "wasm32", no_std)]

#[cfg(target_arch = "wasm32")]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

// ─── Bump allocator ─────────────────────────────────────────────────────────
//
// wasm-ld always emits `__heap_base` for wasm32-unknown-unknown (the address
// right after static data + the shadow stack) even with no allocator crate
// linked. We bump from there and grow linear memory on demand. No `free` —
// fine for a benchmark harness that either runs one buffer per process or
// calls `reset_arena` between phases.

#[cfg(target_arch = "wasm32")]
extern "C" {
    static __heap_base: u8;
}

#[cfg(target_arch = "wasm32")]
static mut BUMP: usize = 0;
#[cfg(target_arch = "wasm32")]
static mut BUMP_INIT: bool = false;

#[cfg(target_arch = "wasm32")]
const PAGE: usize = 65536;

#[cfg(target_arch = "wasm32")]
fn ensure_init() {
    unsafe {
        if !BUMP_INIT {
            BUMP = &__heap_base as *const u8 as usize;
            BUMP_INIT = true;
        }
    }
}

/// Bump-allocate `len` bytes of scratch space in linear memory, growing
/// memory if needed, and return a pointer. Never freed individually — call
/// `reset_arena` to reclaim everything at once.
#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn alloc(len: usize) -> *mut u8 {
    ensure_init();
    unsafe {
        let ptr = BUMP;
        let end = ptr + len;
        let current_bytes = core::arch::wasm32::memory_size(0) * PAGE;
        if end > current_bytes {
            let need = end - current_bytes;
            let grow_pages = (need + PAGE - 1) / PAGE;
            if core::arch::wasm32::memory_grow(0, grow_pages) == usize::MAX {
                core::arch::wasm32::unreachable();
            }
        }
        BUMP = end;
        ptr as *mut u8
    }
}

#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn reset_arena() {
    ensure_init();
    unsafe {
        BUMP = &__heap_base as *const u8 as usize;
    }
}

// ─── Axis 1 rung 1 / the 010 rematch: scalars only ────────────────────────

const COLORS: usize = 6;
const PEGS: usize = 4;

#[inline(always)]
fn score(secret: [i32; PEGS], guess: [i32; PEGS]) -> (i32, i32) {
    let mut blacks = 0;
    let mut secret_leftover = [0i32; COLORS];
    let mut guess_leftover = [0i32; COLORS];

    for i in 0..PEGS {
        if secret[i] == guess[i] {
            blacks += 1;
        } else {
            secret_leftover[secret[i] as usize] += 1;
            guess_leftover[guess[i] as usize] += 1;
        }
    }

    let mut whites = 0;
    for c in 0..COLORS {
        whites += secret_leftover[c].min(guess_leftover[c]);
    }

    (blacks, whites)
}

/// Identical ABI to experiment 010's `score_guess`: 8 scalar i32 in, 1 i32
/// out (blacks*16 + whites). This is the function experiment 010 measured
/// at 24ms/1.68M calls against tuned JS at 40ms.
#[no_mangle]
pub extern "C" fn score_guess(
    s0: i32,
    s1: i32,
    s2: i32,
    s3: i32,
    g0: i32,
    g1: i32,
    g2: i32,
    g3: i32,
) -> i32 {
    let (blacks, whites) = score([s0, s1, s2, s3], [g0, g1, g2, g3]);
    blacks * 16 + whites
}

// ─── Axis 2: granularity sweep on the same score_guess workload ────────────
//
// Batched form of the exact same per-pair computation, but called once for
// N pairs instead of N times for 1 pair each. `secrets`/`guesses` are each
// `n * PEGS` contiguous i32s; `out` receives `n` packed i32 results. This is
// what turns "N calls of 1 unit" into "1 call of N units" for the amortization
// curve — same total work, only the crossing granularity changes.
#[no_mangle]
pub extern "C" fn score_guess_batch(
    secrets_ptr: *const i32,
    guesses_ptr: *const i32,
    n: i32,
    out_ptr: *mut i32,
) {
    let n = n as usize;
    let secrets = unsafe { core::slice::from_raw_parts(secrets_ptr, n * PEGS) };
    let guesses = unsafe { core::slice::from_raw_parts(guesses_ptr, n * PEGS) };
    let out = unsafe { core::slice::from_raw_parts_mut(out_ptr, n) };

    for i in 0..n {
        let base = i * PEGS;
        let s = [
            secrets[base],
            secrets[base + 1],
            secrets[base + 2],
            secrets[base + 3],
        ];
        let g = [
            guesses[base],
            guesses[base + 1],
            guesses[base + 2],
            guesses[base + 3],
        ];
        let (blacks, whites) = score(s, g);
        out[i] = blacks * 16 + whites;
    }
}

// ─── Axis 1 rung 2: typed arrays (contiguous f64 in linear memory) ─────────

/// Safe indexing (bounds-checked, though LLVM can often prove them away for
/// a plain iterator sum — see README for what we actually measured).
#[no_mangle]
pub extern "C" fn sum_f64(ptr: *const f64, len: i32) -> f64 {
    let s = unsafe { core::slice::from_raw_parts(ptr, len as usize) };
    s.iter().sum()
}

/// Same computation, `get_unchecked` in a hand-written index loop instead of
/// an iterator — isolates whatever bounds-check cost survives rustc/LLVM's
/// own elimination in the safe version above.
#[no_mangle]
pub extern "C" fn sum_f64_unchecked(ptr: *const f64, len: i32) -> f64 {
    let len = len as usize;
    let s = unsafe { core::slice::from_raw_parts(ptr, len) };
    let mut acc = 0.0f64;
    let mut i = 0usize;
    while i < len {
        acc += unsafe { *s.get_unchecked(i) };
        i += 1;
    }
    acc
}

// ─── Axis 1 rung 4: strings (UTF-8 bytes in linear memory) ─────────────────

/// FNV-1a over raw bytes. JS must UTF-16 -> UTF-8 encode before this call
/// (via TextEncoder) — that conversion is exactly the marshalling cost this
/// rung is meant to expose.
#[no_mangle]
pub extern "C" fn hash_bytes(ptr: *const u8, len: i32) -> u32 {
    let s = unsafe { core::slice::from_raw_parts(ptr, len as usize) };
    let mut h: u32 = 0x811c9dc5;
    for &b in s {
        h ^= b as u32;
        h = h.wrapping_mul(0x01000193);
    }
    h
}

// ─── Axis 1 rung 5: objects/structs, passed as SoA typed arrays ────────────

/// Sum of Euclidean distance-from-origin over `len` points, given as two
/// separate contiguous f64 arrays (SoA). The JS caller's natural
/// representation is an array of `{x, y}` objects (AoS) — flattening that
/// into two typed arrays before the call IS the marshalling cost this rung
/// measures.
#[no_mangle]
pub extern "C" fn sum_points(xptr: *const f64, yptr: *const f64, len: i32) -> f64 {
    let len = len as usize;
    let xs = unsafe { core::slice::from_raw_parts(xptr, len) };
    let ys = unsafe { core::slice::from_raw_parts(yptr, len) };
    let mut acc = 0.0f64;
    for i in 0..len {
        acc += libm::sqrt(xs[i] * xs[i] + ys[i] * ys[i]);
    }
    acc
}

/// Same task, no `sqrt` — isolates marshalling cost from the "software sqrt
/// vs hardware Math.sqrt" tax that `sum_points` pays (see README: `f64::sqrt`
/// is std-only on stable, so no_std wasm32 needs `libm`'s software
/// implementation here, same root cause as experiment 017's H4 finding for
/// sin/cos/etc — sqrt turns out not to be exempt on stable Rust either).
#[no_mangle]
pub extern "C" fn sum_points_sq(xptr: *const f64, yptr: *const f64, len: i32) -> f64 {
    let len = len as usize;
    let xs = unsafe { core::slice::from_raw_parts(xptr, len) };
    let ys = unsafe { core::slice::from_raw_parts(yptr, len) };
    let mut acc = 0.0f64;
    for i in 0..len {
        acc += xs[i] * xs[i] + ys[i] * ys[i];
    }
    acc
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unpack(packed: i32) -> (i32, i32) {
        (packed / 16, packed % 16)
    }

    #[test]
    fn all_black() {
        assert_eq!(unpack(score_guess(0, 1, 2, 3, 0, 1, 2, 3)), (4, 0));
    }

    #[test]
    fn all_white_reversed() {
        assert_eq!(unpack(score_guess(0, 1, 2, 3, 3, 2, 1, 0)), (0, 4));
    }

    #[test]
    fn repeated_colors_cap_whites_by_multiset() {
        assert_eq!(unpack(score_guess(0, 0, 1, 2, 0, 0, 0, 0)), (2, 0));
    }

    #[test]
    fn hash_bytes_matches_known_fnv1a() {
        // "" -> FNV offset basis; well-known FNV-1a("a") = 0xe40c292c
        assert_eq!(hash_bytes(b"a".as_ptr(), 1), 0xe40c292c);
    }

    #[test]
    fn sum_points_matches_hand_computed_hypot() {
        let xs = [3.0f64, 0.0];
        let ys = [4.0f64, 5.0];
        let total = sum_points(xs.as_ptr(), ys.as_ptr(), 2);
        assert!((total - (5.0 + 5.0)).abs() < 1e-9);
    }
}
