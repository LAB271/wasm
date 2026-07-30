#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "→ Compiling rust/ to wasm32-wasip1..."
(cd rust && cargo build --target wasm32-wasip1 --release)
cp rust/target/wasm32-wasip1/release/line_flood.wasm web/line_flood.wasm
echo "  wrote web/line_flood.wasm ($(wc -c < web/line_flood.wasm) bytes)"

echo "→ Installing + vendoring @bjorn3/browser_wasi_shim..."
(cd web && npm install --no-audit --no-fund >/dev/null)
rm -rf web/vendor
mkdir -p web/vendor/browser_wasi_shim
cp web/node_modules/@bjorn3/browser_wasi_shim/dist/*.js web/vendor/browser_wasi_shim/

echo "→ Done."
