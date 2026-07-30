#!/usr/bin/env bash
# build.sh — compiles the Rust source and vendors the WASI shim, ahead of time.
# Nothing in this script runs at page-load time; index.html only ever reads
# the output of this script.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "→ Compiling rust/ to wasm32-wasip1..."
(cd rust && cargo build --target wasm32-wasip1 --release)
cp rust/target/wasm32-wasip1/release/hello_wasi.wasm web/hello_wasi.wasm
echo "  wrote web/hello_wasi.wasm ($(wc -c < web/hello_wasi.wasm) bytes)"

echo "→ Installing + vendoring @bjorn3/browser_wasi_shim..."
(cd web && npm install --no-audit --no-fund >/dev/null)
rm -rf web/vendor
mkdir -p web/vendor/browser_wasi_shim
cp web/node_modules/@bjorn3/browser_wasi_shim/dist/*.js web/vendor/browser_wasi_shim/
echo "  vendored to web/vendor/browser_wasi_shim/ (no bundler, no CDN, plain relative ESM imports)"

echo "→ Done. Serve web/ with any static file server and open index.html."
