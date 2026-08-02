//! Shared compute core for experiment 017.
//!
//! This crate is compiled into two WASM artifacts:
//!   - `wasm-lib`    (cdylib, wasm32-unknown-unknown) — loaded by JS hosts (node/jsc/js/bun)
//!   - `wasm-driver` (bin, wasm32-wasip1)             — run standalone under wasmtime
//!
//! The PRNG and input-generation formulas here are mirrored **line for line** in
//! `js/common.js`. Both sides use only IEEE-754 binary64 arithmetic (add/sub/mul/div,
//! exact power-of-two division, u32 bit ops) — the exact operations experiment 017's
//! own H3 result confirms are bit-identical across engines — so the two independent
//! implementations produce byte-identical input sequences from the same seed.
//!
//! Do not reorder or "simplify" the arithmetic below without updating js/common.js to
//! match — the whole methodology depends on both sides doing the identical sequence of
//! operations in the identical order.

/// Minimal xorshift32 PRNG. Chosen over anything fancier because every operation is a
/// 32-bit bitwise/shift op — exactly specified in both Rust (`u32` wrapping shifts) and
/// JS (`ToUint32` + `<<`/`>>>`), so there is zero room for cross-language drift.
pub struct Xorshift32 {
    state: u32,
}

impl Xorshift32 {
    pub fn new(seed: u32) -> Self {
        Xorshift32 {
            state: if seed == 0 { 1 } else { seed },
        }
    }

    pub fn next_u32(&mut self) -> u32 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        x
    }
}

/// Magnitude buckets: near-zero, small, medium, large. Picked to stress both the
/// straight-line arithmetic and (for trig) argument-reduction code paths, which is
/// exactly where libm implementations are most likely to disagree.
const BUCKET_SCALES: [f64; 4] = [1e-8, 10.0, 1e4, 1e8];

/// Derive one f64 test input from two PRNG words. `unit` is exact (division by 2^32,
/// a power of two, is exact in IEEE-754 for any 32-bit numerator). The final multiply
/// by a decimal bucket scale is the same single rounding operation in both languages
/// because both parse the `1e8`-style literal to the identical nearest binary64 value.
pub fn next_f64(rng: &mut Xorshift32) -> f64 {
    let hi = rng.next_u32();
    let lo = rng.next_u32();
    let unit = (hi as f64) / 4294967296.0; // hi / 2^32, exact
    let sign: f64 = if (lo & 1) == 1 { -1.0 } else { 1.0 };
    let bucket = ((lo >> 1) & 0b11) as usize;
    sign * unit * BUCKET_SCALES[bucket]
}

/// Same shape, but scaled to a caller-supplied range instead of the bucket table.
/// Used for `pow`'s exponent operand so it doesn't saturate every result to inf/0/NaN.
pub fn next_f64_scaled(rng: &mut Xorshift32, scale: f64) -> f64 {
    let hi = rng.next_u32();
    let lo = rng.next_u32();
    let unit = (hi as f64) / 4294967296.0;
    let sign: f64 = if (lo & 1) == 1 { -1.0 } else { 1.0 };
    sign * unit * scale
}

/// A Weyl-ish odd constant used to derive an independent seed per function, so adding
/// or removing a function from the battery never perturbs another function's inputs.
pub const SEED_STRIDE: u32 = 0x9E3779B1;

pub fn seed_for(base_seed: u32, function_index: u32) -> u32 {
    base_seed.wrapping_add(function_index.wrapping_mul(SEED_STRIDE))
}

// ─── Basic arithmetic (H3 control — expected bit-identical everywhere) ─────────────
//
// Plain `pub fn` (no `no_mangle`/`extern "C"`) — these are called from Rust
// (wasm-lib's cdylib shim, wasm-driver's bin) rather than exposed at the FFI boundary
// directly, so nothing here needs a C ABI or a fixed symbol name of its own.

pub fn add(a: f64, b: f64) -> f64 {
    a + b
}
pub fn sub(a: f64, b: f64) -> f64 {
    a - b
}
pub fn mul(a: f64, b: f64) -> f64 {
    a * b
}
pub fn div(a: f64, b: f64) -> f64 {
    a / b
}
pub fn sqrt(a: f64) -> f64 {
    a.sqrt()
}

// ─── Transcendentals (H1/H2 — implementation-defined per ECMA-262) ─────────────────
// Gated behind the "trig" feature so wasm-lib can be built both with and without this
// code — the size delta between those two builds IS the H4 measurement.
//
// These deliberately call the `libm` crate (a pure-Rust, no_std software
// implementation) instead of `f64::sin()`/etc. Two things forced this, both
// findings in their own right — see README "H4 mechanism" section:
//
//   1. On wasm32-unknown-unknown, `f64::sin()` does NOT link a real implementation —
//      the linker resolves it to a self-referential stub that recurses until the wasm
//      call stack is exhausted. Confirmed by running it under wasmtime. wasm32-wasip1
//      DOES get a working transcendental via wasi-libc, but that's a DIFFERENT
//      implementation than whatever wasm32-unknown-unknown would use.
//   2. Using the same `libm` crate on both targets guarantees the *same* algorithm
//      compiles into both the JS-loaded module (wasm32-unknown-unknown) and the
//      wasmtime-loaded module (wasm32-wasip1) — required for a clean H2 comparison
//      between "WASM via JS host" and "WASM via wasmtime", since otherwise the two
//      targets could silently link two different libms and diverge from each other,
//      confounding the very thing H2 is trying to measure.

#[cfg(feature = "trig")]
pub fn sin(a: f64) -> f64 {
    libm::sin(a)
}
#[cfg(feature = "trig")]
pub fn cos(a: f64) -> f64 {
    libm::cos(a)
}
#[cfg(feature = "trig")]
pub fn tan(a: f64) -> f64 {
    libm::tan(a)
}
#[cfg(feature = "trig")]
pub fn pow(a: f64, b: f64) -> f64 {
    libm::pow(a, b)
}
#[cfg(feature = "trig")]
pub fn exp(a: f64) -> f64 {
    libm::exp(a)
}
#[cfg(feature = "trig")]
pub fn log(a: f64) -> f64 {
    libm::log(a)
}
