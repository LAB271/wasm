#!/bin/bash
# Build every guest leg of experiment 020 into output/, plus the wasmtime host.
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Building Experiment 020: Collections ABI ==="

rustup target add wasm32-unknown-unknown 2>/dev/null || true

OUT=output
mkdir -p "$OUT"

# ─── Leg 1: hand-written WAT ───────────────────────────────────────────────────
echo ""
echo "Leg 1: hand-written WAT..."
wasm-tools parse guests/wat/collections.wat -o "$OUT/wat_collections.wasm"
wasm-tools parse guests/wat/externref.wat   -o "$OUT/wat_externref.wasm"

# ─── Leg 2: Rust, manual ptr+len ───────────────────────────────────────────────
echo ""
echo "Leg 2: Rust manual..."
# Two artifacts from one crate, so the README can quote what HashMap + HashSet
# actually cost a guest binary (see "Guest binary size").
#
# Toggling features forces a full recompile — cargo cannot cache both feature
# sets in one target dir — so the order matters: build the no-hash variant
# FIRST and the default one LAST, and the default build is left in place for
# the harness without a third rebuild to restore it.
echo "  (a) --no-default-features  -> rust_manual_nohash.wasm  [size baseline]"
cargo build --manifest-path guests/rust_manual/Cargo.toml --no-default-features \
    --release --target wasm32-unknown-unknown
cp guests/rust_manual/target/wasm32-unknown-unknown/release/collections_manual.wasm \
   "$OUT/rust_manual_nohash.wasm"

echo "  (b) default features       -> rust_manual.wasm         [the harness loads this]"
cargo build --manifest-path guests/rust_manual/Cargo.toml \
    --release --target wasm32-unknown-unknown
cp guests/rust_manual/target/wasm32-unknown-unknown/release/collections_manual.wasm \
   "$OUT/rust_manual.wasm"

# ─── Leg 3: Rust + wasm-bindgen ────────────────────────────────────────────────
echo ""
echo "Leg 3: Rust + wasm-bindgen..."
if command -v wasm-bindgen &>/dev/null; then
    cargo build --manifest-path guests/rust_bindgen/Cargo.toml \
        --release --target wasm32-unknown-unknown
    wasm-bindgen --target nodejs --out-dir guests/rust_bindgen/pkg \
        guests/rust_bindgen/target/wasm32-unknown-unknown/release/collections_bindgen.wasm
    cp guests/rust_bindgen/pkg/collections_bindgen_bg.wasm "$OUT/rust_bindgen.wasm"
else
    echo "  ! wasm-bindgen CLI not found (cargo install wasm-bindgen-cli) — leg 3 skipped"
fi

# ─── Leg 4: AssemblyScript ─────────────────────────────────────────────────────
echo ""
echo "Leg 4: AssemblyScript..."
( cd guests/assemblyscript && [ -d node_modules ] || npm install --silent )
( cd guests/assemblyscript && npx asc assembly/index.ts --config asconfig.json --target release )
cp guests/assemblyscript/build/collections.wasm "$OUT/assemblyscript.wasm"

# ─── Leg 5: Component Model / WIT ──────────────────────────────────────────────
echo ""
echo "Leg 5: Component Model..."
cargo build --manifest-path guests/component/Cargo.toml \
    --release --target wasm32-unknown-unknown
cp guests/component/target/wasm32-unknown-unknown/release/collections_component.wasm \
   "$OUT/component_core.wasm"
wasm-tools component new "$OUT/component_core.wasm" -o "$OUT/component.wasm"

# ─── Host ──────────────────────────────────────────────────────────────────────
echo ""
echo "Host (wasmtime)..."
cargo build --manifest-path host/Cargo.toml --release

# ─── Shared workload, so the Node leg benchmarks identical bytes ───────────────
echo ""
echo "Dumping shared workload..."
( cd host && ./target/release/collections_host --dump ../output/workload )

echo ""
echo "Artifacts (raw, and after wasm-opt -Oz):"
for w in "$OUT"/*.wasm; do
    wasm-opt -Oz --enable-bulk-memory --enable-reference-types --enable-multivalue \
        "$w" -o /tmp/020oz.wasm 2>/dev/null \
        && oz=$(wc -c < /tmp/020oz.wasm | tr -d ' ') || oz="n/a"
    printf "  %-40s %8d B   -Oz %8s B\n" "$w" "$(wc -c < "$w")" "$oz"
done
