#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=5004

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1" >&2; exit 1; }

command -v python3 &>/dev/null || fail "python3 not found"

cd "$SCRIPT_DIR"

# Create venv if needed and install dependencies
if [ ! -d .venv ]; then
  info "Creating virtual environment..."
  python3 -m venv .venv
  .venv/bin/pip install --quiet flask psycopg2-binary
fi

info "Starting Flask + psycopg2 on port $PORT..."
.venv/bin/python app.py &
PID=$!

for i in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/" &>/dev/null && break
  sleep 0.2
done

ok "Listening on http://127.0.0.1:$PORT/"
echo "  Try: curl http://127.0.0.1:$PORT/db?id=1"
echo "  Stop: kill $PID"
wait "$PID"
