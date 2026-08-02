#!/bin/bash
# Runs js/portable_battery.js (the 010-rematch scalar comparison) across every
# JS engine on this machine. Pattern lifted from experiment 017's
# run_matrix.sh — Node is primary; this is the secondary "does the gap hold
# across engines" check.
set -euo pipefail
cd "$(dirname "$0")"

JSC_BIN="/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc"

mkdir -p results
rm -f results/*.csv results/*.stderr

echo "=== Experiment 020: multi-engine scalar rematch ==="
echo ""

run_host() {
    local name="$1"
    local cmd="$2"
    if command -v "$cmd" >/dev/null 2>&1 || [ -x "$cmd" ]; then
        echo "-> $name ($cmd)"
        "$cmd" js/portable_battery.js > "results/${name}.csv" 2> "results/${name}.stderr" || {
            echo "   FAILED — see results/${name}.stderr"
            tail -5 "results/${name}.stderr" | sed 's/^/   /'
        }
        grep '^#' "results/${name}.csv" | sed 's/^/   /'
    else
        echo "-> $name: not found, skipping ($cmd not on PATH)"
    fi
    echo ""
}

run_host "node" "node"
run_host "bun" "bun"
run_host "jsc" "$JSC_BIN"
run_host "spidermonkey" "js"

echo "=== Summary (wasm vs js_bitpacked ratio per engine) ==="
for f in results/*.csv; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .csv)
    ratio=$(grep '^# ratio wasm_vs_bitpacked=' "$f" | cut -d= -f2)
    [ -n "$ratio" ] && printf "  %-14s %s\n" "$name" "$ratio"
done
