#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=5005

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1" >&2; exit 1; }

command -v node &>/dev/null || fail "node not found — brew install node"
command -v npm  &>/dev/null || fail "npm not found — brew install node"

cd "$SCRIPT_DIR"
[ -d node_modules ] || npm install --silent

info "Starting Node.js + Pyodide + pg bridge on port $PORT..."
node harness.js &
PID=$!

for i in $(seq 1 100); do
  curl -sf "http://127.0.0.1:$PORT/" &>/dev/null && break
  sleep 0.1
done

ok "Listening on http://127.0.0.1:$PORT/"
echo "  Try: curl http://127.0.0.1:$PORT/db?id=1"
echo "  Stop: kill $PID"
wait "$PID"
