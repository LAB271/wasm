#!/bin/bash
# Build all legs of the stdlib size experiment.
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Building Experiment 012: Stdlib Size Matrix ==="

# Ensure target is available
rustup target add wasm32-unknown-unknown 2>/dev/null || true

# Check for wasm-opt
if ! command -v wasm-opt &>/dev/null; then
    echo "Warning: wasm-opt not found. Install with: cargo install wasm-opt"
    echo "Legs 3/4 will be skipped."
    HAS_WASM_OPT=0
else
    HAS_WASM_OPT=1
fi

OUT=output
mkdir -p "$OUT"

# Target dir is inside app/
TARGET="app/target/wasm32-unknown-unknown"

# ─── Leg 1: Baseline (debug) ───────────────────────────────────────────────────

echo ""
echo "Leg 1: Baseline (no optimization)..."
cargo build --manifest-path app/Cargo.toml --target wasm32-unknown-unknown
cp "$TARGET/debug/mastermind_wasm.wasm" "$OUT/leg1_baseline.wasm"

# ─── Leg 2: Release + LTO ──────────────────────────────────────────────────────

echo ""
echo "Leg 2: Release + LTO..."

# Create a temporary Cargo.toml with LTO enabled
cat > app/Cargo.toml.leg2 << 'EOF'
[package]
name = "mastermind-wasm"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
mvl-stdlib = { path = "../stdlib", default-features = false, features = ["strings", "random", "collections"] }

[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
EOF

mv app/Cargo.toml app/Cargo.toml.bak
mv app/Cargo.toml.leg2 app/Cargo.toml

cargo build --manifest-path app/Cargo.toml --target wasm32-unknown-unknown --release
cp "$TARGET/release/mastermind_wasm.wasm" "$OUT/leg2_lto.wasm"

mv app/Cargo.toml.bak app/Cargo.toml

# ─── Leg 3: Release + wasm-opt -Oz ─────────────────────────────────────────────

if [ "$HAS_WASM_OPT" -eq 1 ]; then
    echo ""
    echo "Leg 3: Release + wasm-opt -Oz..."

    cargo build --manifest-path app/Cargo.toml --target wasm32-unknown-unknown --release
    wasm-opt -Oz "$TARGET/release/mastermind_wasm.wasm" -o "$OUT/leg3_wasm_opt.wasm"
fi

# ─── Leg 4: Release + LTO + wasm-opt -Oz ───────────────────────────────────────

if [ "$HAS_WASM_OPT" -eq 1 ]; then
    echo ""
    echo "Leg 4: Release + LTO + wasm-opt -Oz..."

    # Use LTO config
    mv app/Cargo.toml app/Cargo.toml.bak
    cat > app/Cargo.toml << 'EOF'
[package]
name = "mastermind-wasm"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
mvl-stdlib = { path = "../stdlib", default-features = false, features = ["strings", "random", "collections"] }

[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
EOF

    cargo build --manifest-path app/Cargo.toml --target wasm32-unknown-unknown --release
    wasm-opt -Oz "$TARGET/release/mastermind_wasm.wasm" -o "$OUT/leg4_lto_wasm_opt.wasm"

    mv app/Cargo.toml.bak app/Cargo.toml
fi

# ─── Leg 5: Feature flags (strings only) ───────────────────────────────────────

echo ""
echo "Leg 5: Minimal features (strings only)..."

# Create minimal app that only uses strings
cat > app/Cargo.toml.leg5 << 'EOF'
[package]
name = "mastermind-wasm"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
mvl-stdlib = { path = "../stdlib", default-features = false, features = ["strings"] }

[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
EOF

# Create minimal lib.rs that doesn't use random
cat > app/src/lib.rs.leg5 << 'EOF'
//! Minimal Mastermind (no random) for size comparison.

#![no_std]
#![allow(static_mut_refs)]

extern crate alloc;
use alloc::vec::Vec;

use mvl_stdlib::strings;

/// Scoring result for one guess.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Feedback {
    pub blacks: u8,
    pub whites: u8,
}

/// Count positions where guess matches secret exactly.
fn count_blacks(secret: &[u8], guess: &[u8]) -> u8 {
    let mut n = 0u8;
    for i in 0..secret.len().min(guess.len()) {
        if secret[i] == guess[i] {
            n += 1;
        }
    }
    n
}

/// Count occurrences of `color` in `xs` at positions where `xs[i] != other[i]`.
fn count_color_at_mismatch(xs: &[u8], other: &[u8], color: u8) -> u8 {
    let mut n = 0u8;
    for i in 0..xs.len().min(other.len()) {
        if xs[i] == color && xs[i] != other[i] {
            n += 1;
        }
    }
    n
}

/// Score `guess` against `secret`.
pub fn score_guess(secret: &[u8], guess: &[u8]) -> Feedback {
    let blacks = count_blacks(secret, guess);
    let mut whites = 0u8;
    for color in 1..=6 {
        let in_secret = count_color_at_mismatch(secret, guess, color);
        let in_guess = count_color_at_mismatch(guess, secret, color);
        whites += in_secret.min(in_guess);
    }
    Feedback { blacks, whites }
}

/// Parse a guess line like "1 2 3 4" into a code.
pub fn parse_guess(input: &str) -> Option<Vec<u8>> {
    let trimmed = strings::trim(input);
    if strings::is_empty(trimmed) {
        return None;
    }

    let parts = strings::split(trimmed, " ");
    let non_empty: Vec<&str> = parts.into_iter().filter(|s| !s.is_empty()).collect();

    if non_empty.len() != 4 {
        return None;
    }

    let mut code = Vec::with_capacity(4);
    for part in non_empty {
        match strings::parse_int(part) {
            Some(n) if n >= 1 && n <= 6 => code.push(n as u8),
            _ => return None,
        }
    }

    Some(code)
}

/// Score a guess against a secret.
#[unsafe(no_mangle)]
pub extern "C" fn score(secret: u32, guess: u32) -> u16 {
    let s = [
        ((secret >> 24) & 0xFF) as u8,
        ((secret >> 16) & 0xFF) as u8,
        ((secret >> 8) & 0xFF) as u8,
        (secret & 0xFF) as u8,
    ];
    let g = [
        ((guess >> 24) & 0xFF) as u8,
        ((guess >> 16) & 0xFF) as u8,
        ((guess >> 8) & 0xFF) as u8,
        (guess & 0xFF) as u8,
    ];
    let fb = score_guess(&s, &g);
    ((fb.blacks as u16) << 8) | (fb.whites as u16)
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[cfg(not(test))]
mod alloc_impl {
    use core::alloc::{GlobalAlloc, Layout};

    struct BumpAllocator;

    static mut HEAP: [u8; 8192] = [0; 8192];
    static mut HEAP_PTR: usize = 0;
    const HEAP_SIZE: usize = 8192;

    unsafe impl GlobalAlloc for BumpAllocator {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            let align = layout.align();
            let size = layout.size();
            let ptr = HEAP_PTR;
            let aligned = (ptr + align - 1) & !(align - 1);
            let new_ptr = aligned + size;
            if new_ptr > HEAP_SIZE {
                core::ptr::null_mut()
            } else {
                HEAP_PTR = new_ptr;
                HEAP.as_mut_ptr().add(aligned)
            }
        }

        unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {}
    }

    #[global_allocator]
    static ALLOCATOR: BumpAllocator = BumpAllocator;
}
EOF

mv app/Cargo.toml app/Cargo.toml.bak
mv app/src/lib.rs app/src/lib.rs.bak
mv app/Cargo.toml.leg5 app/Cargo.toml
mv app/src/lib.rs.leg5 app/src/lib.rs

cargo build --manifest-path app/Cargo.toml --target wasm32-unknown-unknown --release

if [ "$HAS_WASM_OPT" -eq 1 ]; then
    wasm-opt -Oz "$TARGET/release/mastermind_wasm.wasm" -o "$OUT/leg5_minimal.wasm"
else
    cp "$TARGET/release/mastermind_wasm.wasm" "$OUT/leg5_minimal.wasm"
fi

mv app/src/lib.rs.bak app/src/lib.rs
mv app/Cargo.toml.bak app/Cargo.toml

# ─── Leg 6: Full stdlib (for reference) ────────────────────────────────────────

echo ""
echo "Leg 6: Full stdlib (all features)..."

cat > app/Cargo.toml.leg6 << 'EOF'
[package]
name = "mastermind-wasm"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
mvl-stdlib = { path = "../stdlib", default-features = true }

[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
EOF

mv app/Cargo.toml app/Cargo.toml.bak
mv app/Cargo.toml.leg6 app/Cargo.toml

cargo build --manifest-path app/Cargo.toml --target wasm32-unknown-unknown --release

if [ "$HAS_WASM_OPT" -eq 1 ]; then
    wasm-opt -Oz "$TARGET/release/mastermind_wasm.wasm" -o "$OUT/leg6_full_stdlib.wasm"
else
    cp "$TARGET/release/mastermind_wasm.wasm" "$OUT/leg6_full_stdlib.wasm"
fi

mv app/Cargo.toml.bak app/Cargo.toml

# ─── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Build Complete ==="
echo ""
echo "Output files in $OUT/:"
ls -la "$OUT/"*.wasm 2>/dev/null || echo "(no wasm files)"

echo ""
echo "Run ./benchmark.sh for size analysis."
