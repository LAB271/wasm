#!/usr/bin/env bash
# Builds the four size/debuggability tiers (see README.md) plus the two
# zero-import variants used only for `wasmtime run --profile=guest`
# (custom imports aren't satisfiable by the wasmtime CLI). Copies everything
# into output/ with descriptive names, and builds the native wasmtime host.
set -euo pipefail
cd "$(dirname "$0")"

MODULE=module
HOST=host
OUT=output
mkdir -p "$OUT"

echo "==> module: native unit tests"
(cd "$MODULE" && cargo test --quiet)

echo "==> tier1: fully optimized (no_std, opt-level=z, lto, panic=abort, strip=true)"
(cd "$MODULE" && cargo build --target wasm32-unknown-unknown --profile tier1 --features nostd)
wasm-opt -Oz "$MODULE/target/wasm32-unknown-unknown/tier1/wasm_debug_demo.wasm" -o "$OUT/tier1_fully_optimized.wasm"

echo "==> tier2: optimized + names (strip=\"debuginfo\" only, wasm-opt -g keeps names)"
(cd "$MODULE" && cargo build --target wasm32-unknown-unknown --profile tier2 --features nostd)
wasm-opt -Oz -g "$MODULE/target/wasm32-unknown-unknown/tier2/wasm_debug_demo.wasm" -o "$OUT/tier2_optimized_names.wasm"

echo "==> tier3: release + debug info (std, opt-level=3, panic=unwind, debug=true, no wasm-opt)"
(cd "$MODULE" && cargo build --target wasm32-unknown-unknown --profile tier3)
cp "$MODULE/target/wasm32-unknown-unknown/tier3/wasm_debug_demo.wasm" "$OUT/tier3_release_debuginfo.wasm"

echo "==> tier4: full debug (std, dev profile, opt-level=0, no wasm-opt)"
(cd "$MODULE" && cargo build --target wasm32-unknown-unknown)
cp "$MODULE/target/wasm32-unknown-unknown/debug/wasm_debug_demo.wasm" "$OUT/tier4_full_debug.wasm"

echo "==> profiling variants: zero-import builds for wasmtime --profile=guest"
(cd "$MODULE" && cargo build --target wasm32-unknown-unknown --profile profiling --no-default-features --features nostd)
cp "$MODULE/target/wasm32-unknown-unknown/profiling/wasm_debug_demo.wasm" "$OUT/profiling_no_names.wasm"
(cd "$MODULE" && cargo build --target wasm32-unknown-unknown --profile profiling-names --no-default-features --features nostd)
cp "$MODULE/target/wasm32-unknown-unknown/profiling-names/wasm_debug_demo.wasm" "$OUT/profiling_with_names.wasm"
(cd "$MODULE" && cargo build --target wasm32-unknown-unknown --profile profiling-dwarf --no-default-features)
cp "$MODULE/target/wasm32-unknown-unknown/profiling-dwarf/wasm_debug_demo.wasm" "$OUT/profiling_with_dwarf.wasm"

echo "==> native wasmtime host (host_log importer + trap reporter)"
(cd "$HOST" && cargo build --release --quiet)

echo ""
echo "Done. Artifacts in $OUT/:"
ls -la "$OUT"
