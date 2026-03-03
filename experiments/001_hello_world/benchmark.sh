#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEY_N=1000
HEY_C=1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1" >&2; exit 1; }

command -v hey &>/dev/null || fail "hey not found — brew install hey"

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

# ── Helper: cold-start measurement ──────────────────────────────────────────
cold_start_ms() {
  local port=$1
  local start end
  start=$(date +%s%3N)
  for i in $(seq 1 100); do
    curl -sf "http://127.0.0.1:$port/" &>/dev/null && break
    sleep 0.1
  done
  end=$(date +%s%3N)
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
    p50) echo "$out" | grep "50% in" | awk '{printf "%.1f", $3*1000}' ;;
    p99) echo "$out" | grep "99% in" | awk '{printf "%.1f", $3*1000}' ;;
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

# ── LEG 2: Pyodide / Chromium ────────────────────────────────────────────────
info "Leg 2: Pyodide / Chromium (port 5002)"
cd "$SCRIPT_DIR/leg2_pyodide_chromium"
[ -d node_modules ] || npm install --silent
ARTIFACT_2=$(du -sh node_modules 2>/dev/null | cut -f1)B

node harness.js &
LEG2_PID=$!
COLD_2=$(cold_start_ms 5002)
ok "cold start: ${COLD_2}ms  artifact: $ARTIFACT_2"

HEY_2=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5002/")
RSS_2=$(rss_mb "$LEG2_PID")
kill "$LEG2_PID" 2>/dev/null; wait "$LEG2_PID" 2>/dev/null || true
ok "hey done  rss: ${RSS_2}MB  p50: $(hey_stat "$HEY_2" p50)ms  rps: $(hey_stat "$HEY_2" rps)"

# ── LEG 3: Wasmtime ──────────────────────────────────────────────────────────
info "Leg 3: Wasmtime (port 5003)"
cd "$SCRIPT_DIR/leg3_wasmtime"
cargo build --target wasm32-wasip2 --release --quiet 2>&1
WASM=$(find target/wasm32-wasip2/release -maxdepth 1 -name "*.wasm" | head -1)
ARTIFACT_3=$(du -sh "$WASM" | cut -f1)B

wasmtime serve --addr "127.0.0.1:5003" "$WASM" &
LEG3_PID=$!
COLD_3=$(cold_start_ms 5003)
ok "cold start: ${COLD_3}ms  artifact: $ARTIFACT_3"

HEY_3=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5003/")
RSS_3=$(rss_mb "$LEG3_PID")
kill "$LEG3_PID" 2>/dev/null; wait "$LEG3_PID" 2>/dev/null || true
ok "hey done  rss: ${RSS_3}MB  p50: $(hey_stat "$HEY_3" p50)ms  rps: $(hey_stat "$HEY_3" rps)"

# ── Results table ─────────────────────────────────────────────────────────────
echo ""
echo "## Results"
echo ""
printf "| %-22s | %-20s | %-22s | %-16s |\n" "Metric" "Leg 1 Flask/Podman" "Leg 2 Pyodide/Chrome" "Leg 3 Wasmtime"
printf "| %-22s | %-20s | %-22s | %-16s |\n" "---" "---" "---" "---"
printf "| %-22s | %-20s | %-22s | %-16s |\n" "Artifact size"        "$ARTIFACT_1"                  "$ARTIFACT_2"                   "$ARTIFACT_3"
printf "| %-22s | %-20s | %-22s | %-16s |\n" "Cold start (ms)"      "${COLD_1}"                     "${COLD_2}"                      "${COLD_3}"
printf "| %-22s | %-20s | %-22s | %-16s |\n" "Memory RSS (MB)"      "${RSS_1}"                      "${RSS_2}"                       "${RSS_3}"
printf "| %-22s | %-20s | %-22s | %-16s |\n" "hey p50 (ms)"         "$(hey_stat "$HEY_1" p50)"      "$(hey_stat "$HEY_2" p50)"       "$(hey_stat "$HEY_3" p50)"
printf "| %-22s | %-20s | %-22s | %-16s |\n" "hey p99 (ms)"         "$(hey_stat "$HEY_1" p99)"      "$(hey_stat "$HEY_2" p99)"       "$(hey_stat "$HEY_3" p99)"
printf "| %-22s | %-20s | %-22s | %-16s |\n" "hey req/s"            "$(hey_stat "$HEY_1" rps)"      "$(hey_stat "$HEY_2" rps)"       "$(hey_stat "$HEY_3" rps)"
echo ""
