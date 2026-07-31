#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "→ Compiling guest/ to wasm32-unknown-unknown..."
(cd guest && cargo build --target wasm32-unknown-unknown --release)
echo "  wrote guest/target/wasm32-unknown-unknown/release/transform_guest.wasm ($(wc -c < guest/target/wasm32-unknown-unknown/release/transform_guest.wasm) bytes)"

echo "→ Compiling host/ (embeds the wasmtime crate)..."
(cd host && cargo build --release)

echo "→ Done."
