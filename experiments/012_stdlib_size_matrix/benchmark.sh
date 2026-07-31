#!/bin/bash
# Benchmark WASM sizes for stdlib experiment.
set -euo pipefail
cd "$(dirname "$0")"

OUT=output

if [ ! -d "$OUT" ] || [ -z "$(ls -A "$OUT"/*.wasm 2>/dev/null)" ]; then
    echo "No WASM files found. Run ./build.sh first."
    exit 1
fi

echo "=== Experiment 012: Stdlib Size Benchmark ==="
echo ""
printf "%-25s %10s %10s %10s\n" "Leg" ".wasm" "gzip" "brotli"
printf "%-25s %10s %10s %10s\n" "---" "-----" "----" "------"

for wasm in "$OUT"/*.wasm; do
    name=$(basename "$wasm" .wasm)
    size=$(wc -c < "$wasm" | tr -d ' ')

    # gzip size
    gzip_size=$(gzip -c "$wasm" | wc -c | tr -d ' ')

    # brotli size (if available)
    if command -v brotli &>/dev/null; then
        brotli_size=$(brotli -c "$wasm" | wc -c | tr -d ' ')
    else
        brotli_size="-"
    fi

    printf "%-25s %10s %10s %10s\n" "$name" "$size" "$gzip_size" "$brotli_size"
done

echo ""
echo "Sizes in bytes. Lower is better."
echo ""

# Show relative comparisons
if [ -f "$OUT/leg1_baseline.wasm" ] && [ -f "$OUT/leg4_lto_wasm_opt.wasm" ]; then
    baseline=$(wc -c < "$OUT/leg1_baseline.wasm" | tr -d ' ')
    optimized=$(wc -c < "$OUT/leg4_lto_wasm_opt.wasm" | tr -d ' ')
    reduction=$((100 - (optimized * 100 / baseline)))
    echo "LTO + wasm-opt -Oz reduces baseline by ${reduction}%"
fi

if [ -f "$OUT/leg4_lto_wasm_opt.wasm" ] && [ -f "$OUT/leg5_minimal.wasm" ]; then
    full=$(wc -c < "$OUT/leg4_lto_wasm_opt.wasm" | tr -d ' ')
    minimal=$(wc -c < "$OUT/leg5_minimal.wasm" | tr -d ' ')
    reduction=$((100 - (minimal * 100 / full)))
    echo "Feature flags (strings only) reduces by ${reduction}% vs full"
fi
