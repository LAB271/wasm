#!/bin/bash
# Runs the full {JS impl, WASM impl} x {host} matrix and prints the divergence report.
# Requires ./build.sh to have produced output/*.wasm first.
set -euo pipefail
cd "$(dirname "$0")"

JSC_BIN="/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc"

mkdir -p results
rm -f results/*.csv

echo "=== Experiment 017: Float Determinism — running matrix ==="
echo ""

run_host() {
    local name="$1"
    local cmd="$2"
    if command -v "$cmd" >/dev/null 2>&1 || [ -x "$cmd" ]; then
        echo "-> $name ($cmd)"
        "$cmd" js/battery.js > "results/${name}.csv" 2> "results/${name}.stderr" || {
            echo "   FAILED — see results/${name}.stderr"
            tail -5 "results/${name}.stderr" | sed 's/^/   /'
        }
    else
        echo "-> $name: not found, skipping ($cmd not on PATH)"
    fi
}

run_host "node" "node"
run_host "jsc" "$JSC_BIN"
run_host "spidermonkey" "js"
run_host "bun" "bun"

echo "-> wasmtime (output/wasm-driver.wasm, no JS involved)"
if command -v wasmtime >/dev/null 2>&1; then
    wasmtime run output/wasm-driver.wasm > results/wasmtime.csv 2> results/wasmtime.stderr || {
        echo "   FAILED — see results/wasmtime.stderr"
    }
else
    echo "   not found, skipping"
fi

echo ""
echo "=== Divergence matrix ==="
node js/compare.js results/ | tee results/report.txt

echo ""
echo "=== H4 mechanism check — imports & size delta ==="
echo ""
echo "Imports in output/determinism_full.wasm (should be none — no host math imports):"
if command -v wasm-objdump >/dev/null 2>&1; then
    IMPORTS=$(wasm-objdump -x output/determinism_full.wasm | awk '/^Import\[/{flag=1;next}/^[A-Z][a-z]+\[/{flag=0}flag')
    if [ -z "$IMPORTS" ]; then
        echo "  (none)"
    else
        echo "$IMPORTS"
    fi
else
    echo "  wasm-objdump not found — install via 'brew install wabt'"
fi

echo ""
echo "Size delta — arith-only vs full (trig feature), same source, same compiler flags:"
if [ -f output/determinism_arith_only.wasm ] && [ -f output/determinism_full.wasm ]; then
    ARITH_SIZE=$(wc -c < output/determinism_arith_only.wasm | tr -d ' ')
    FULL_SIZE=$(wc -c < output/determinism_full.wasm | tr -d ' ')
    DELTA=$((FULL_SIZE - ARITH_SIZE))
    echo "  arith-only (add/sub/mul/div/sqrt only): ${ARITH_SIZE} bytes"
    echo "  full (+ sin/cos/tan/pow/exp/log):       ${FULL_SIZE} bytes"
    echo "  delta (the bundled libm, made visible): ${DELTA} bytes"
else
    echo "  build output missing — run ./build.sh first"
fi

echo ""
echo "Full report saved to results/report.txt"
