//! Thin cdylib shim. Re-exports `compute`'s functions as top-level `no_mangle` symbols
//! so they land in the wasm export table unambiguously (re-exporting a dependency
//! crate's `#[no_mangle]` fn through a cdylib boundary is fine in practice, but defining
//! them directly in the cdylib's own crate root removes any doubt).
//!
//! Built twice (see ../../Makefile):
//!   - `--features trig`  → full build, used for the actual determinism matrix
//!   - (no features)      → arith-only build, used ONLY to measure the libm size delta (H4)

#[no_mangle]
pub extern "C" fn add(a: f64, b: f64) -> f64 {
    compute::add(a, b)
}
#[no_mangle]
pub extern "C" fn sub(a: f64, b: f64) -> f64 {
    compute::sub(a, b)
}
#[no_mangle]
pub extern "C" fn mul(a: f64, b: f64) -> f64 {
    compute::mul(a, b)
}
#[no_mangle]
pub extern "C" fn div(a: f64, b: f64) -> f64 {
    compute::div(a, b)
}
#[no_mangle]
pub extern "C" fn sqrt(a: f64) -> f64 {
    compute::sqrt(a)
}

#[cfg(feature = "trig")]
#[no_mangle]
pub extern "C" fn sin(a: f64) -> f64 {
    compute::sin(a)
}
#[cfg(feature = "trig")]
#[no_mangle]
pub extern "C" fn cos(a: f64) -> f64 {
    compute::cos(a)
}
#[cfg(feature = "trig")]
#[no_mangle]
pub extern "C" fn tan(a: f64) -> f64 {
    compute::tan(a)
}
#[cfg(feature = "trig")]
#[no_mangle]
pub extern "C" fn pow(a: f64, b: f64) -> f64 {
    compute::pow(a, b)
}
#[cfg(feature = "trig")]
#[no_mangle]
pub extern "C" fn exp(a: f64) -> f64 {
    compute::exp(a)
}
#[cfg(feature = "trig")]
#[no_mangle]
pub extern "C" fn log(a: f64) -> f64 {
    compute::log(a)
}
