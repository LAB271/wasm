#!/usr/bin/env bash
# H2 + H5 check: for each tier, trigger the real panic path (trigger_panic(4))
# under both the native wasmtime host and Node, and exercise the host-imported
# logging path (log_and_compute(5)) under both. Prints real captured output —
# this is the source of the "before/after" stack trace samples in README.md.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=host/target/release/wasm-debug-host

for f in output/tier1_fully_optimized.wasm output/tier2_optimized_names.wasm \
         output/tier3_release_debuginfo.wasm output/tier4_full_debug.wasm; do
  echo "############################################################"
  echo "# $f"
  echo "############################################################"
  echo "--- wasmtime native host: trigger_panic(4) ---"
  "$HOST" "$f" trigger_panic 4 || true
  echo
  echo "--- Node/V8: trigger_panic(4) ---"
  node tests/run_wasm.mjs "$f" trigger_panic 4 || true
  echo
  echo "--- wasmtime native host: log_and_compute(5) ---"
  "$HOST" "$f" log_and_compute 5
  echo "--- Node/V8: log_and_compute(5) ---"
  node tests/run_wasm.mjs "$f" log_and_compute 5
  echo
done
