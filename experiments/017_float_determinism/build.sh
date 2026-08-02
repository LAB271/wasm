#!/bin/bash
# Build both wasm-lib variants (full / arith-only) and the wasmtime driver.
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Building Experiment 017: Float Determinism ==="

rustup target add wasm32-unknown-unknown wasm32-wasip1 2>/dev/null || true

mkdir -p output

echo ""
echo "wasm-lib (full — trig feature on, used by JS hosts for the matrix)..."
cargo build --manifest-path rust/wasm-lib/Cargo.toml \
    --target wasm32-unknown-unknown --release --features trig
cp rust/wasm-lib/target/wasm32-unknown-unknown/release/wasm_lib.wasm \
    output/determinism_full.wasm

echo ""
echo "wasm-lib (arith-only — no trig feature, size-delta comparison only)..."
cargo build --manifest-path rust/wasm-lib/Cargo.toml \
    --target wasm32-unknown-unknown --release
cp rust/wasm-lib/target/wasm32-unknown-unknown/release/wasm_lib.wasm \
    output/determinism_arith_only.wasm

echo ""
echo "wasm-driver (wasip1 — standalone battery runner for the wasmtime leg)..."
cargo build --manifest-path rust/wasm-driver/Cargo.toml \
    --target wasm32-wasip1 --release
cp rust/wasm-driver/target/wasm32-wasip1/release/wasm-driver.wasm \
    output/wasm-driver.wasm

echo ""
echo "=== Build complete ==="
wc -c output/*.wasm
