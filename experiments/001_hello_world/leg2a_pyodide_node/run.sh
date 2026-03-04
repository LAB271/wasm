#!/usr/bin/env bash
set -euo pipefail

PORT=5002
DIR="$(cd "$(dirname "$0")" && pwd)"

command -v node &>/dev/null || { echo "✗ node not found — brew install node" >&2; exit 1; }
command -v npm  &>/dev/null || { echo "✗ npm not found (ships with node)" >&2; exit 1; }

cd "$DIR"

if [ ! -d node_modules ]; then
  echo "→ Installing dependencies..."
  npm install --silent
fi

echo "→ Starting Pyodide harness on port $PORT..."
node harness.js &
HARNESS_PID=$!

# Wait for readiness
echo -n "→ Waiting for HTTP..."
for i in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:$PORT/" &>/dev/null; then
    echo " ready"
    curl -s "http://127.0.0.1:$PORT/" | python3 -m json.tool
    wait "$HARNESS_PID"
    exit 0
  fi
  sleep 0.5
done

echo " timeout" >&2
kill "$HARNESS_PID" 2>/dev/null || true
exit 1
