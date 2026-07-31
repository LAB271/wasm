#!/bin/bash
# Build all legs of the Unicode strategies experiment.
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Building Experiment 013: Unicode Strategies ==="

# Ensure targets are available
rustup target add wasm32-unknown-unknown 2>/dev/null || true

# Check for wasm-opt
if ! command -v wasm-opt &>/dev/null; then
    echo "Warning: wasm-opt not found. Binaries will not be optimized."
    HAS_WASM_OPT=0
else
    HAS_WASM_OPT=1
fi

# ─── Leg 1: Embedded Unicode Tables ────────────────────────────────────────────

echo ""
echo "Leg 1: Embedded Unicode tables..."

mkdir -p legs/leg1_embedded

# Build with embedded feature
cargo build --manifest-path unicode-lib/Cargo.toml \
    --target wasm32-unknown-unknown \
    --release \
    --no-default-features \
    --features embedded

if [ "$HAS_WASM_OPT" -eq 1 ]; then
    wasm-opt -Oz target/wasm32-unknown-unknown/release/unicode_lib.wasm \
        -o legs/leg1_embedded/output.wasm
else
    cp target/wasm32-unknown-unknown/release/unicode_lib.wasm \
        legs/leg1_embedded/output.wasm
fi

echo "  → legs/leg1_embedded/output.wasm"

# ─── Leg 2: Host Delegation (JS) ───────────────────────────────────────────────

echo ""
echo "Leg 2: Host delegation (JS)..."

mkdir -p legs/leg2_host_js

# Build with host feature
cargo build --manifest-path unicode-lib/Cargo.toml \
    --target wasm32-unknown-unknown \
    --release \
    --no-default-features \
    --features host

if [ "$HAS_WASM_OPT" -eq 1 ]; then
    wasm-opt -Oz target/wasm32-unknown-unknown/release/unicode_lib.wasm \
        -o legs/leg2_host_js/output.wasm
else
    cp target/wasm32-unknown-unknown/release/unicode_lib.wasm \
        legs/leg2_host_js/output.wasm
fi

echo "  → legs/leg2_host_js/output.wasm"

# ─── Leg 3: ASCII Only ─────────────────────────────────────────────────────────

echo ""
echo "Leg 3: ASCII only..."

mkdir -p legs/leg3_ascii_only

# Build with ascii feature
cargo build --manifest-path unicode-lib/Cargo.toml \
    --target wasm32-unknown-unknown \
    --release \
    --no-default-features \
    --features ascii

if [ "$HAS_WASM_OPT" -eq 1 ]; then
    wasm-opt -Oz target/wasm32-unknown-unknown/release/unicode_lib.wasm \
        -o legs/leg3_ascii_only/output.wasm
else
    cp target/wasm32-unknown-unknown/release/unicode_lib.wasm \
        legs/leg3_ascii_only/output.wasm
fi

echo "  → legs/leg3_ascii_only/output.wasm"

# ─── Leg 4: ASCII No Import ────────────────────────────────────────────────────

echo ""
echo "Leg 4: ASCII, no imports..."

mkdir -p legs/leg4_ascii_no_import

# Same as Leg 3 (ascii feature doesn't have host imports anyway)
# This is to demonstrate the baseline without any external dependencies
cp legs/leg3_ascii_only/output.wasm legs/leg4_ascii_no_import/output.wasm

echo "  → legs/leg4_ascii_no_import/output.wasm"

# ─── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Build Complete ==="
echo ""
echo "Output files:"

for leg in legs/leg*/output.wasm; do
    size=$(wc -c < "$leg" | tr -d ' ')
    echo "  $leg: ${size} bytes"
done

echo ""
echo "Run ./benchmark.sh for full analysis."
echo "To test in browser: cd host && python3 -m http.server 8080"
