#!/usr/bin/env bash
# build.sh — compile the mastermind CLI guest to wasm32-wasip1 and the
# embedded host that runs it with explicit WASI stdio wiring.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "→ guest: cargo build --release --target wasm32-wasip1"
(cd guest && cargo build --release --target wasm32-wasip1)

echo "→ host: cargo build --release"
(cd host && cargo build --release)

echo
echo "done. Run with either:"
echo "  wasmtime run guest/target/wasm32-wasip1/release/mastermind-guest.wasm"
echo "  ./host/target/release/mastermind-host"
