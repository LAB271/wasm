#!/bin/bash
# Benchmark Unicode strategies.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d "legs" ] || [ -z "$(ls -A legs/*/output.wasm 2>/dev/null)" ]; then
    echo "No WASM files found. Run ./build.sh first."
    exit 1
fi

echo "=== Experiment 013: Unicode Strategies Benchmark ==="
echo ""

# ─── Size Comparison ───────────────────────────────────────────────────────────

echo "Size Comparison"
echo "───────────────"
printf "%-30s %10s %10s %10s\n" "Leg" ".wasm" "gzip" "brotli"
printf "%-30s %10s %10s %10s\n" "---" "-----" "----" "------"

for leg in legs/*/output.wasm; do
    name=$(dirname "$leg" | xargs basename)
    size=$(wc -c < "$leg" | tr -d ' ')
    gzip_size=$(gzip -c "$leg" | wc -c | tr -d ' ')

    if command -v brotli &>/dev/null; then
        brotli_size=$(brotli -c "$leg" | wc -c | tr -d ' ')
    else
        brotli_size="-"
    fi

    printf "%-30s %10s %10s %10s\n" "$name" "$size" "$gzip_size" "$brotli_size"
done

echo ""

# ─── Feature Analysis ──────────────────────────────────────────────────────────

echo "Feature Analysis"
echo "────────────────"

# Embedded vs ASCII difference
if [ -f "legs/leg1_embedded/output.wasm" ] && [ -f "legs/leg3_ascii_only/output.wasm" ]; then
    embedded=$(wc -c < "legs/leg1_embedded/output.wasm" | tr -d ' ')
    ascii=$(wc -c < "legs/leg3_ascii_only/output.wasm" | tr -d ' ')
    diff=$((embedded - ascii))
    echo "Unicode tables add: ${diff} bytes ($(echo "scale=1; $diff / 1024" | bc) KB)"
fi

# Host delegation size
if [ -f "legs/leg2_host_js/output.wasm" ]; then
    host=$(wc -c < "legs/leg2_host_js/output.wasm" | tr -d ' ')
    echo "Host delegation module: ${host} bytes"
fi

echo ""

# ─── WASM Function Analysis ────────────────────────────────────────────────────

if command -v wasm-objdump &>/dev/null; then
    echo "Exports per leg"
    echo "───────────────"

    for leg in legs/*/output.wasm; do
        name=$(dirname "$leg" | xargs basename)
        exports=$(wasm-objdump -x "$leg" 2>/dev/null | grep -c "^ - func" || echo "0")
        imports=$(wasm-objdump -x "$leg" 2>/dev/null | grep -c "^ - func\[" || echo "0")
        echo "$name: $exports exports"
    done

    echo ""
fi

# ─── Correctness Matrix ────────────────────────────────────────────────────────

echo "Expected Correctness Matrix"
echo "───────────────────────────"
echo ""
echo "| Test case          | Embedded | Host JS | ASCII |"
echo "|--------------------|----------|---------|-------|"
echo "| ASCII to_upper     |    ✓     |    ✓    |   ✓   |"
echo "| Latin-1 to_upper   |    ✓     |    ✓    |   ✗   |"
echo "| Greek to_upper     |    ✓     |    ✓    |   ✗   |"
echo "| Cyrillic to_upper  |    ✓     |    ✓    |   ✗   |"
echo "| Unicode whitespace |    ✓     |    ✓    |   ✗   |"
echo "| Grapheme counting  |    ✗     |    ✓    |   ✗   |"
echo ""
echo "(Host JS requires browser with Intl.Segmenter for grapheme counting)"
echo ""
echo "To run browser tests: cd host && python3 -m http.server 8080"
echo "Then open http://localhost:8080/test.html"
