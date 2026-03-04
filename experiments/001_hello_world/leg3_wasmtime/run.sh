#!/usr/bin/env bash
set -euo pipefail

PORT=5003
DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure Rust/cargo is on PATH — respects CARGO_HOME (XDG-compliant)
export PATH="${CARGO_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/cargo}/bin:$PATH"

command -v cargo    &>/dev/null || { echo "✗ cargo not found — install rustup" >&2; exit 1; }
command -v wasmtime &>/dev/null || { echo "✗ wasmtime not found — brew install wasmtime" >&2; exit 1; }

# Ensure wasm32-wasip2 target is available
if ! rustup target list --installed 2>/dev/null | grep -q "wasm32-wasip2"; then
  echo "→ Adding wasm32-wasip2 Rust target..."
  rustup target add wasm32-wasip2
fi

cd "$DIR"

echo "→ Building Rust WASM component (wasm32-wasip2)..."
cargo build --target wasm32-wasip2 --release 2>&1

WASM=$(find target/wasm32-wasip2/release -maxdepth 1 -name "*.wasm" | head -1)
if [ -z "$WASM" ]; then
  echo "✗ No .wasm file found in target/wasm32-wasip2/release/" >&2
  exit 1
fi
echo "→ Binary: $WASM ($(du -sh "$WASM" | cut -f1))"

echo "→ Starting wasmtime serve on port $PORT..."
wasmtime serve --addr "127.0.0.1:$PORT" "$WASM" &
WASMTIME_PID=$!

# Wait for readiness
echo -n "→ Waiting for HTTP..."
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT/" &>/dev/null; then
    echo " ready"
    curl -s "http://127.0.0.1:$PORT/" | python3 -m json.tool
    wait "$WASMTIME_PID"
    exit 0
  fi
  sleep 0.2
done

echo " timeout" >&2
kill "$WASMTIME_PID" 2>/dev/null || true
exit 1
