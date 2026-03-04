#!/usr/bin/env bash
set -euo pipefail

WASM_PORT=5006
SIDECAR_PORT=5007
DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1" >&2; exit 1; }

# Ensure Rust/cargo is on PATH
export PATH="${CARGO_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/cargo}/bin:$PATH"

command -v cargo    &>/dev/null || fail "cargo not found — install rustup"
command -v wasmtime &>/dev/null || fail "wasmtime not found — brew install wasmtime"
command -v node     &>/dev/null || fail "node not found"
command -v npm      &>/dev/null || fail "npm not found"

# Ensure wasm32-wasip2 target is available
if ! rustup target list --installed 2>/dev/null | grep -q "wasm32-wasip2"; then
  info "Adding wasm32-wasip2 Rust target..."
  rustup target add wasm32-wasip2
fi

cd "$DIR"

# Install sidecar dependencies
[ -d node_modules ] || npm install --silent

# Build WASM component
info "Building Rust WASM component (wasm32-wasip2)..."
cargo build --target wasm32-wasip2 --release 2>&1

WASM=$(find target/wasm32-wasip2/release -maxdepth 1 -name "*.wasm" | head -1)
[ -z "$WASM" ] && fail "No .wasm file found in target/wasm32-wasip2/release/"
ok "Binary: $WASM ($(du -sh "$WASM" | cut -f1))"

cleanup() {
  kill "$SIDECAR_PID" 2>/dev/null || true
  kill "$WASMTIME_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Start sidecar
info "Starting Node.js sidecar on port $SIDECAR_PORT..."
node sidecar.js &
SIDECAR_PID=$!

# Wait for sidecar readiness
for i in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$SIDECAR_PORT/query?id=1" &>/dev/null && break
  sleep 0.1
done

# Start wasmtime serve
info "Starting wasmtime serve on port $WASM_PORT..."
wasmtime serve -S cli -S inherit-network --addr "127.0.0.1:$WASM_PORT" "$WASM" &
WASMTIME_PID=$!

# Wait for WASM readiness
echo -n "  → Waiting for HTTP..."
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$WASM_PORT/" &>/dev/null; then
    echo " ready"
    ok "Listening on http://127.0.0.1:$WASM_PORT/"
    echo "  Try: curl http://127.0.0.1:$WASM_PORT/db?id=1"
    echo "  Stop: kill $WASMTIME_PID $SIDECAR_PID"
    curl -s "http://127.0.0.1:$WASM_PORT/db?id=1" | python3 -m json.tool
    trap - EXIT
    wait "$WASMTIME_PID"
    exit 0
  fi
  sleep 0.2
done

echo " timeout" >&2
exit 1
