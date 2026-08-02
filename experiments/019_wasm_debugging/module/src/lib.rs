// Test module for experiment 019 (WASM debuggability vs binary size). One
// crate, one target (wasm32-unknown-unknown, same as experiment 010), built
// across four tiers that trade size for debug info. See ../README.md.
#![cfg_attr(feature = "nostd", no_std)]

// no_std needs its own panic handler. We deliberately trap (real WASM
// `unreachable` instruction) instead of looping forever (010's browser-only
// handler does `loop {}`) so the panic path is observable: a hung tab tells
// you nothing, a trap gives every host (wasmtime, Node, browser) a
// catchable error with a stack trace to inspect. Cargo.toml's `panic =
// "abort"` for tier1/tier2 means this handler runs directly on panic, no
// unwinding attempted.
#[cfg(feature = "nostd")]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

// Host import used for the H5 (host-imported logging) check: forwards a
// static byte slice across the WASM boundary. No formatting, no allocation
// — a raw pointer+length pair, so it compiles identically whether or not
// std/alloc are available, and the same .wasm binary can be driven by a JS
// host (Node) or a native Rust host (wasmtime embedding) that both provide
// an `env.host_log` import with this exact signature.
// Gated behind the "hostlog" feature (on by default) so a `--no-default-features`
// build has *zero* imports — needed for `wasmtime run --profile=guest`,
// whose CLI can only satisfy WASI imports, not arbitrary custom ones. See
// scripts/profile_guest.sh.
#[cfg(all(target_arch = "wasm32", feature = "hostlog"))]
#[link(wasm_import_module = "env")]
extern "C" {
    fn host_log(ptr: *const u8, len: usize);
}

/// Iterative fibonacci — deterministic compute payload, no host imports, no
/// panics. Used as the "does it even run" smoke test and the base workload
/// for size measurement.
#[no_mangle]
pub extern "C" fn fibonacci(n: u32) -> u64 {
    let (mut a, mut b): (u64, u64) = (0, 1);
    for _ in 0..n {
        let next = a + b;
        a = b;
        b = next;
    }
    a
}

// extern "C" functions cannot unwind (UB since the 2021 edition; rustc
// inserts an abort guard at the FFI boundary) — so the actual panic logic
// lives in a plain Rust fn, tested natively below, and the exported
// `extern "C"` wrapper is a thin pass-through for the WASM ABI.
const LUT: [u64; 4] = [0, 1, 1, 2];

fn trigger_panic_impl(n: u32) -> u64 {
    LUT[n as usize] + fibonacci(n)
}

/// Computes fibonacci(n) but deliberately traps via an out-of-bounds index
/// once n >= LUT.len() (4). Same deterministic panic path exercised in every
/// tier, so stack traces are directly comparable across the matrix. Call
/// with n=4 to trigger the trap; n<4 returns normally.
#[no_mangle]
pub extern "C" fn trigger_panic(n: u32) -> u64 {
    trigger_panic_impl(n)
}

/// Exercises the host-imported logging path (H5): sends a static string
/// across the boundary via `host_log`, then returns fibonacci(n). Only
/// compiled for wasm32 targets — `host_log` is a WASM import with no native
/// equivalent, so native `cargo test` builds skip this function entirely.
#[cfg(all(target_arch = "wasm32", feature = "hostlog"))]
#[no_mangle]
pub extern "C" fn log_and_compute(n: u32) -> u64 {
    static MSG: &[u8] = b"hello from wasm-debug-demo";
    unsafe {
        host_log(MSG.as_ptr(), MSG.len());
    }
    fibonacci(n)
}

// Native-only unit tests (run via `cargo test`, no WASM involved) — mirrors
// 010's pattern of testing scoring logic natively before it ever touches a
// WASM target. Only compiled when std is available (default features).
#[cfg(all(test, not(feature = "nostd")))]
mod tests {
    use super::*;

    #[test]
    fn fibonacci_known_values() {
        assert_eq!(fibonacci(0), 0);
        assert_eq!(fibonacci(1), 1);
        assert_eq!(fibonacci(10), 55);
    }

    #[test]
    fn trigger_panic_stays_in_bounds_below_four() {
        assert_eq!(trigger_panic_impl(3), 2 + fibonacci(3)); // LUT[3] == 2
    }

    #[test]
    #[should_panic]
    fn trigger_panic_traps_at_four() {
        // Calls the plain-Rust impl directly (not the extern "C" export) —
        // panicking across an extern "C" boundary aborts instead of
        // unwinding in the 2021+ edition, which would break #[should_panic].
        trigger_panic_impl(4);
    }
}
