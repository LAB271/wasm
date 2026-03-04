#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEY_N=1000
HEY_C=1

# Ensure Rust/cargo is on PATH — respects CARGO_HOME (XDG-compliant)
export PATH="${CARGO_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/cargo}/bin:$PATH"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1" >&2; exit 1; }

command -v hey &>/dev/null || fail "hey not found — brew install hey"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
PIDS_TO_KILL=()
cleanup() {
  for pid in "${PIDS_TO_KILL[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  ${CONTAINER_CMD:-podman} rm -f bench-postgres leg1-flask 2>/dev/null || true
}
trap cleanup EXIT

# ── Detect container runtime ────────────────────────────────────────────────
if [ -z "${CONTAINER_CMD:-}" ]; then
  if command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
    CONTAINER_CMD="podman"
  elif command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    CONTAINER_CMD="docker"
  else
    fail "No running container runtime (podman or docker). Run: ./install.sh --start"
  fi
fi

# ── Helper: milliseconds since epoch (macOS-safe) ────────────────────────────
now_ms() { python3 -c "import time; print(int(time.time()*1000))"; }

# ── Helper: cold-start measurement ──────────────────────────────────────────
cold_start_ms() {
  local port=$1 path=${2:-/}
  local start end
  start=$(now_ms)
  for i in $(seq 1 100); do
    curl -sf "http://127.0.0.1:$port$path" &>/dev/null && break
    sleep 0.1
  done
  end=$(now_ms)
  echo $(( end - start ))
}

# ── Helper: RSS in MB ────────────────────────────────────────────────────────
rss_mb() {
  local pid=$1
  ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo "?"
}

# ── Helper: parse hey output ─────────────────────────────────────────────────
hey_stat() {
  local out=$1 stat=$2
  case "$stat" in
    p50) echo "$out" | grep "50%%" | awk '{printf "%.1f", $3*1000}' ;;
    p99) echo "$out" | grep "99%%" | awk '{printf "%.1f", $3*1000}' ;;
    rps) echo "$out" | grep "Requests/sec:" | awk '{printf "%.0f", $2}' ;;
  esac
}

echo ""
echo "════════════════════════════════════════════════"
echo "  Experiment 001 — Hello World Benchmark"
echo "════════════════════════════════════════════════"
echo ""

# ── LEG 1: Flask / Podman ────────────────────────────────────────────────────
info "Leg 1: Flask / $CONTAINER_CMD (port 5001)"
$CONTAINER_CMD rm -f leg1-flask &>/dev/null || true
$CONTAINER_CMD build -t leg1-flask "$SCRIPT_DIR/leg1_flask_docker" &>/dev/null
ARTIFACT_1=$(CONTAINER_CMD=$CONTAINER_CMD $CONTAINER_CMD image inspect leg1-flask --format '{{.Size}}' \
  | awk '{printf "%.0fMB", $1/1048576}')

COLD_START_BEGIN=$(date +%s%3N)
$CONTAINER_CMD run -d --name leg1-flask -p 5001:5001 leg1-flask &>/dev/null
COLD_1=$(cold_start_ms 5001)
ok "cold start: ${COLD_1}ms  artifact: $ARTIFACT_1"

LEG1_PID=$($CONTAINER_CMD inspect --format '{{.State.Pid}}' leg1-flask 2>/dev/null || echo 0)
HEY_1=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5001/")
RSS_1=$(rss_mb "$LEG1_PID")
$CONTAINER_CMD rm -f leg1-flask &>/dev/null
ok "hey done  rss: ${RSS_1}MB  p50: $(hey_stat "$HEY_1" p50)ms  rps: $(hey_stat "$HEY_1" rps)"

# ── LEG 2a: Pyodide / Node.js (no browser) ───────────────────────────────────
info "Leg 2a: Pyodide / Node.js (port 5002)"
pushd "$SCRIPT_DIR/leg2a_pyodide_node" >/dev/null
[ -d node_modules ] || npm install --silent
ARTIFACT_2A=$(du -sh node_modules 2>/dev/null | cut -f1)B

node harness.js &
LEG2A_PID=$!
PIDS_TO_KILL+=("$LEG2A_PID")
COLD_2A=$(cold_start_ms 5002)
ok "cold start: ${COLD_2A}ms  artifact: $ARTIFACT_2A"

HEY_2A=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5002/")
RSS_2A=$(rss_mb "$LEG2A_PID")
kill "$LEG2A_PID" 2>/dev/null; wait "$LEG2A_PID" 2>/dev/null || true
ok "hey done  rss: ${RSS_2A}MB  p50: $(hey_stat "$HEY_2A" p50)ms  rps: $(hey_stat "$HEY_2A" rps)"
popd >/dev/null

# ── LEG 2b: Pyodide / Chromium (real headless Chrome) ────────────────────────
info "Leg 2b: Pyodide / Chromium (port 5008)"
pushd "$SCRIPT_DIR/leg2b_pyodide_chromium" >/dev/null
[ -d node_modules ] || npm install --silent
ARTIFACT_2B=$(du -sh node_modules 2>/dev/null | cut -f1)B

node harness.js &
LEG2B_PID=$!
PIDS_TO_KILL+=("$LEG2B_PID")
COLD_2B=$(cold_start_ms 5008)
ok "cold start: ${COLD_2B}ms  artifact: $ARTIFACT_2B"

HEY_2B=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5008/")
# Sum RSS of Node.js harness + all Chrome descendant processes
# (Chrome spawns renderer, GPU, utility children — pgrep -P only finds direct children)
descendant_pids() {
  local parent=$1
  for child in $(pgrep -P "$parent" 2>/dev/null); do
    echo "$child"
    descendant_pids "$child"
  done
}
RSS_2B_NODE=$(rss_mb "$LEG2B_PID")
RSS_2B_CHROME=$(descendant_pids "$LEG2B_PID" | xargs -I{} ps -o rss= -p {} 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}')
RSS_2B_CHROME=${RSS_2B_CHROME:-0}
RSS_2B=$(( ${RSS_2B_NODE:-0} + RSS_2B_CHROME ))
kill "$LEG2B_PID" 2>/dev/null; wait "$LEG2B_PID" 2>/dev/null || true
ok "hey done  rss: ${RSS_2B}MB (node:${RSS_2B_NODE}+chrome:${RSS_2B_CHROME})  p50: $(hey_stat "$HEY_2B" p50)ms  rps: $(hey_stat "$HEY_2B" rps)"
popd >/dev/null

# ── LEG 3: Wasmtime ──────────────────────────────────────────────────────────
info "Leg 3: Wasmtime (port 5003)"
pushd "$SCRIPT_DIR/leg3_wasmtime" >/dev/null
cargo build --target wasm32-wasip2 --release --quiet 2>&1
WASM=$(find target/wasm32-wasip2/release -maxdepth 1 -name "*.wasm" | head -1)
ARTIFACT_3=$(du -sh "$WASM" | cut -f1)B

wasmtime serve -S cli --addr "127.0.0.1:5003" "$WASM" &
LEG3_PID=$!
PIDS_TO_KILL+=("$LEG3_PID")
COLD_3=$(cold_start_ms 5003)
ok "cold start: ${COLD_3}ms  artifact: $ARTIFACT_3"

HEY_3=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5003/")
RSS_3=$(rss_mb "$LEG3_PID")
kill "$LEG3_PID" 2>/dev/null; wait "$LEG3_PID" 2>/dev/null || true
ok "hey done  rss: ${RSS_3}MB  p50: $(hey_stat "$HEY_3" p50)ms  rps: $(hey_stat "$HEY_3" rps)"
popd >/dev/null

# ── POSTGRES: shared database for legs 4a/4b ─────────────────────────────────
info "Starting Postgres for legs 4a/4b/4c..."

# Check port 5432 is available
if lsof -i :5432 &>/dev/null; then
  fail "Port 5432 already in use — stop local Postgres first"
fi

$CONTAINER_CMD rm -f bench-postgres &>/dev/null || true
$CONTAINER_CMD run -d --name bench-postgres \
  -e POSTGRES_USER=bench \
  -e POSTGRES_PASSWORD=bench \
  -e POSTGRES_DB=bench \
  -p 5432:5432 \
  docker.io/library/postgres:16-alpine &>/dev/null

# Wait for Postgres to accept connections
for i in $(seq 1 50); do
  $CONTAINER_CMD exec bench-postgres pg_isready -U bench &>/dev/null && break
  sleep 0.2
done
ok "Postgres ready"

# Seed the items table
$CONTAINER_CMD cp "$SCRIPT_DIR/shared/postgres_init.sql" bench-postgres:/tmp/init.sql
$CONTAINER_CMD exec bench-postgres psql -U bench -d bench -f /tmp/init.sql &>/dev/null
ok "Database seeded"

# ── LEG 4a: Flask + psycopg2 / direct Postgres ──────────────────────────────
info "Leg 4a: Flask + psycopg2 / direct (port 5004)"
pushd "$SCRIPT_DIR/leg4a_flask_postgres" >/dev/null
if [ ! -d .venv ]; then
  python3 -m venv .venv
  .venv/bin/pip install --quiet 'flask==3.1.*' 'psycopg2-binary==2.9.*'
fi
ARTIFACT_4A=$(du -sh .venv 2>/dev/null | cut -f1)B

.venv/bin/python app.py &>/dev/null &
LEG4A_PID=$!
PIDS_TO_KILL+=("$LEG4A_PID")
COLD_4A=$(cold_start_ms 5004 "/db?id=1")
ok "cold start: ${COLD_4A}ms  artifact: $ARTIFACT_4A"

HEY_4A=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5004/db?id=1")
RSS_4A=$(rss_mb "$LEG4A_PID")
kill "$LEG4A_PID" 2>/dev/null; wait "$LEG4A_PID" 2>/dev/null || true
ok "hey done  rss: ${RSS_4A}MB  p50: $(hey_stat "$HEY_4A" p50)ms  rps: $(hey_stat "$HEY_4A" rps)"
popd >/dev/null

# ── LEG 4b: Node.js + Pyodide + pg bridge ───────────────────────────────────
info "Leg 4b: Pyodide + pg bridge (port 5005)"
pushd "$SCRIPT_DIR/leg4b_wasm_postgres_bridge" >/dev/null
[ -d node_modules ] || npm install --silent
ARTIFACT_4B=$(du -sh node_modules 2>/dev/null | cut -f1)B

node harness.js &
LEG4B_PID=$!
PIDS_TO_KILL+=("$LEG4B_PID")
COLD_4B=$(cold_start_ms 5005 "/db?id=1")
ok "cold start: ${COLD_4B}ms  artifact: $ARTIFACT_4B"

HEY_4B=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5005/db?id=1")
RSS_4B=$(rss_mb "$LEG4B_PID")
kill "$LEG4B_PID" 2>/dev/null; wait "$LEG4B_PID" 2>/dev/null || true
ok "hey done  rss: ${RSS_4B}MB  p50: $(hey_stat "$HEY_4B" p50)ms  rps: $(hey_stat "$HEY_4B" rps)"
popd >/dev/null

# ── LEG 4c: Rust/Wasmtime + Node.js sidecar → Postgres ─────────────────────
info "Leg 4c: Wasmtime + sidecar (port 5006)"
pushd "$SCRIPT_DIR/leg4c_wasmtime_postgres" >/dev/null
[ -d node_modules ] || npm install --silent
cargo build --target wasm32-wasip2 --release --quiet 2>&1
WASM_4C=$(find target/wasm32-wasip2/release -maxdepth 1 -name "*.wasm" | head -1)
ARTIFACT_4C=$(du -sh "$WASM_4C" | cut -f1)B

node sidecar.js &
SIDECAR_PID=$!
PIDS_TO_KILL+=("$SIDECAR_PID")
# Wait for sidecar
for i in $(seq 1 50); do
  curl -sf "http://127.0.0.1:5007/query?id=1" &>/dev/null && break
  sleep 0.1
done
curl -sf "http://127.0.0.1:5007/query?id=1" &>/dev/null \
  || fail "Sidecar did not become ready on port 5007"

wasmtime serve -S cli -S inherit-network --addr "127.0.0.1:5006" "$WASM_4C" &
LEG4C_PID=$!
PIDS_TO_KILL+=("$LEG4C_PID")
COLD_4C=$(cold_start_ms 5006 "/db?id=1")
ok "cold start: ${COLD_4C}ms  artifact: $ARTIFACT_4C"

HEY_4C=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5006/db?id=1")
RSS_4C_WASM=$(rss_mb "$LEG4C_PID")
RSS_4C_SIDE=$(rss_mb "$SIDECAR_PID")
RSS_4C=$(( ${RSS_4C_WASM:-0} + ${RSS_4C_SIDE:-0} ))
kill "$LEG4C_PID" 2>/dev/null; wait "$LEG4C_PID" 2>/dev/null || true
kill "$SIDECAR_PID" 2>/dev/null; wait "$SIDECAR_PID" 2>/dev/null || true
ok "hey done  rss: ${RSS_4C}MB (wasm:${RSS_4C_WASM}+sidecar:${RSS_4C_SIDE})  p50: $(hey_stat "$HEY_4C" p50)ms  rps: $(hey_stat "$HEY_4C" rps)"
popd >/dev/null

# ── Postgres cleanup ─────────────────────────────────────────────────────────
$CONTAINER_CMD rm -f bench-postgres &>/dev/null
ok "Postgres stopped"

# ── Results table ─────────────────────────────────────────────────────────────
echo ""
echo "## Results — Hello World (legs 1–3)"
echo ""
printf "| %-22s | %-20s | %-22s | %-22s | %-16s |\n" "Metric" "Leg 1 Flask/Podman" "Leg 2a Pyodide/Node" "Leg 2b Pyodide/Chrome" "Leg 3 Wasmtime"
printf "| %-22s | %-20s | %-22s | %-22s | %-16s |\n" "---" "---" "---" "---" "---"
printf "| %-22s | %-20s | %-22s | %-22s | %-16s |\n" "Artifact size"        "$ARTIFACT_1"                  "$ARTIFACT_2A"                  "$ARTIFACT_2B"                  "$ARTIFACT_3"
printf "| %-22s | %-20s | %-22s | %-22s | %-16s |\n" "Cold start (ms)"      "${COLD_1}"                     "${COLD_2A}"                     "${COLD_2B}"                     "${COLD_3}"
printf "| %-22s | %-20s | %-22s | %-22s | %-16s |\n" "Memory RSS (MB)"      "${RSS_1}"                      "${RSS_2A}"                      "${RSS_2B}"                      "${RSS_3}"
printf "| %-22s | %-20s | %-22s | %-22s | %-16s |\n" "hey p50 (ms)"         "$(hey_stat "$HEY_1" p50)"      "$(hey_stat "$HEY_2A" p50)"      "$(hey_stat "$HEY_2B" p50)"      "$(hey_stat "$HEY_3" p50)"
printf "| %-22s | %-20s | %-22s | %-22s | %-16s |\n" "hey p99 (ms)"         "$(hey_stat "$HEY_1" p99)"      "$(hey_stat "$HEY_2A" p99)"      "$(hey_stat "$HEY_2B" p99)"      "$(hey_stat "$HEY_3" p99)"
printf "| %-22s | %-20s | %-22s | %-22s | %-16s |\n" "hey req/s"            "$(hey_stat "$HEY_1" rps)"      "$(hey_stat "$HEY_2A" rps)"      "$(hey_stat "$HEY_2B" rps)"      "$(hey_stat "$HEY_3" rps)"
echo ""

echo "## Results — Postgres DB query (legs 4a/4b/4c)"
echo ""
printf "| %-22s | %-24s | %-24s | %-24s |\n" "Metric" "Leg 4a Flask+psycopg2" "Leg 4b Pyodide+pg bridge" "Leg 4c Wasmtime+sidecar"
printf "| %-22s | %-24s | %-24s | %-24s |\n" "---" "---" "---" "---"
printf "| %-22s | %-24s | %-24s | %-24s |\n" "Artifact size"        "$ARTIFACT_4A"                    "$ARTIFACT_4B"                    "$ARTIFACT_4C"
printf "| %-22s | %-24s | %-24s | %-24s |\n" "Cold start (ms)"      "${COLD_4A}"                       "${COLD_4B}"                       "${COLD_4C}"
printf "| %-22s | %-24s | %-24s | %-24s |\n" "Memory RSS (MB)"      "${RSS_4A}"                        "${RSS_4B}"                        "${RSS_4C}"
printf "| %-22s | %-24s | %-24s | %-24s |\n" "hey p50 (ms)"         "$(hey_stat "$HEY_4A" p50)"        "$(hey_stat "$HEY_4B" p50)"        "$(hey_stat "$HEY_4C" p50)"
printf "| %-22s | %-24s | %-24s | %-24s |\n" "hey p99 (ms)"         "$(hey_stat "$HEY_4A" p99)"        "$(hey_stat "$HEY_4B" p99)"        "$(hey_stat "$HEY_4C" p99)"
printf "| %-22s | %-24s | %-24s | %-24s |\n" "hey req/s"            "$(hey_stat "$HEY_4A" rps)"        "$(hey_stat "$HEY_4B" rps)"        "$(hey_stat "$HEY_4C" rps)"
echo ""
