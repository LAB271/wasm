#!/bin/bash
# Build the crossover wasm module: one cargo artifact (opt-level=3, LTO,
# codegen-units=1), post-processed two ways with wasm-opt so we can compare
# a size-tuned (-Oz) and a speed-tuned (-O3) binary from identical source.
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Building Experiment 020: JS vs WASM crossover ==="

rustup target add wasm32-unknown-unknown 2>/dev/null || true

mkdir -p output

echo ""
echo "cargo build --release --target wasm32-unknown-unknown ..."
cargo build --manifest-path rust/crossover/Cargo.toml \
    --target wasm32-unknown-unknown --release

RAW=rust/crossover/target/wasm32-unknown-unknown/release/crossover.wasm

echo ""
echo "wasm-opt -Oz (size-tuned) ..."
wasm-opt -Oz "$RAW" -o output/crossover_oz.wasm

echo "wasm-opt -O3 (speed-tuned) ..."
wasm-opt -O3 "$RAW" -o output/crossover_o3.wasm

cp "$RAW" output/crossover_raw.wasm

echo ""
echo "Validating..."
wasm-tools validate output/crossover_oz.wasm
wasm-tools validate output/crossover_o3.wasm
echo "  ok"

echo ""
echo "=== Build complete ==="
wc -c output/crossover_raw.wasm output/crossover_oz.wasm output/crossover_o3.wasm
