#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "→ Compiling rust/ (loop_pure, loop_alloc) to wasm32-wasip1..."
(cd rust && cargo build --target wasm32-wasip1 --release)
cp rust/target/wasm32-wasip1/release/loop_pure.wasm web/loop_pure.wasm
cp rust/target/wasm32-wasip1/release/loop_alloc.wasm web/loop_alloc.wasm
echo "  wrote web/loop_pure.wasm ($(wc -c < web/loop_pure.wasm) bytes), web/loop_alloc.wasm ($(wc -c < web/loop_alloc.wasm) bytes)"

echo "→ Installing + vendoring @bjorn3/browser_wasi_shim..."
(cd web && npm install --no-audit --no-fund >/dev/null)
rm -rf web/vendor
mkdir -p web/vendor/browser_wasi_shim
cp web/node_modules/@bjorn3/browser_wasi_shim/dist/*.js web/vendor/browser_wasi_shim/

echo "→ Installing harness dependencies (playwright)..."
npm install --no-audit --no-fund >/dev/null
npx playwright install chromium >/dev/null 2>&1 || true

echo "→ Done. Run ./benchmark.sh, or serve web/ with web/coi_server.py directly."
