#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$EXPERIMENTS_DIR/lib/bench.sh"

HEY_N=${HEY_N:-1000}
HEY_C=${HEY_C:-1}

# Ensure Rust/cargo is on PATH — respects CARGO_HOME (XDG-compliant)
export PATH="${CARGO_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/cargo}/bin:$PATH"

command -v hey &>/dev/null || fail "hey not found — brew install hey"

CONTAINER_CMD=$(detect_container_cmd)

# ── Cleanup trap ──────────────────────────────────────────────────────────────
PIDS_TO_KILL=()
cleanup() {
  for pid in "${PIDS_TO_KILL[@]}"; do
    kill_and_wait "$pid"
  done
  $CONTAINER_CMD rm -f bench-postgres leg1-flask 2>/dev/null || true
}
trap cleanup EXIT

# ── Per-leg failure tracking ──────────────────────────────────────────────────
FAILED_LEGS=()

run_leg() {
  local name=$1; shift
  if ! "$@"; then
    FAILED_LEGS+=("$name")
    echo -e "  ${RED}✗ $name FAILED${NC}" >&2
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 1: Flask / Podman
# ══════════════════════════════════════════════════════════════════════════════
run_leg1() {
  info "Leg 1: Flask / $CONTAINER_CMD (port 5001)"
  require_port_free 5001 "Leg 1 Flask"

  APP_1=$(human_size "$SCRIPT_DIR/leg1_flask_docker/app.py")
  $CONTAINER_CMD rm -f leg1-flask &>/dev/null || true
  $CONTAINER_CMD build -t leg1-flask "$SCRIPT_DIR/leg1_flask_docker" &>/dev/null
  RUNTIME_1=$(CONTAINER_CMD=$CONTAINER_CMD $CONTAINER_CMD image inspect leg1-flask --format '{{.Size}}' \
    | awk '{printf "%.0fMB", $1/1048576}')

  $CONTAINER_CMD run -d --name leg1-flask -p 5001:5001 leg1-flask &>/dev/null
  COLD_1=$(cold_start_ms 5001)
  ok "cold start: ${COLD_1}ms  app: $APP_1  runtime: $RUNTIME_1"

  LEG1_PID=$($CONTAINER_CMD inspect --format '{{.State.Pid}}' leg1-flask 2>/dev/null || echo 0)
  HEY_1=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5001/")
  RSS_1=$(rss_mb "$LEG1_PID")
  $CONTAINER_CMD rm -f leg1-flask &>/dev/null
  ok "hey done  rss: ${RSS_1}MB  p50: $(hey_stat "$HEY_1" p50)ms  rps: $(hey_stat "$HEY_1" rps)"
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 2a: Pyodide / Node.js (no browser)
# ══════════════════════════════════════════════════════════════════════════════
run_leg2a() {
  info "Leg 2a: Pyodide / Node.js (port 5002)"
  require_port_free 5002 "Leg 2a Pyodide/Node"

  pushd "$SCRIPT_DIR/leg2a_pyodide_node" >/dev/null
  [ -d node_modules ] || npm install --silent
  APP_2A=$(human_size harness.js)
  RUNTIME_2A=$(du -sh node_modules 2>/dev/null | cut -f1)B

  node harness.js &
  LEG2A_PID=$!
  PIDS_TO_KILL+=("$LEG2A_PID")
  COLD_2A=$(cold_start_ms 5002)
  ok "cold start: ${COLD_2A}ms  app: $APP_2A  runtime: $RUNTIME_2A"

  HEY_2A=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5002/")
  RSS_2A=$(rss_mb "$LEG2A_PID")
  kill_and_wait "$LEG2A_PID"
  ok "hey done  rss: ${RSS_2A}MB  p50: $(hey_stat "$HEY_2A" p50)ms  rps: $(hey_stat "$HEY_2A" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 2b: Pyodide / Chromium (Puppeteer)
# ══════════════════════════════════════════════════════════════════════════════
run_leg2b() {
  info "Leg 2b: Pyodide / Chromium (port 5008)"
  require_port_free 5008 "Leg 2b Pyodide/Chrome"

  pushd "$SCRIPT_DIR/leg2b_pyodide_chromium" >/dev/null
  [ -d node_modules ] || npm install --silent
  APP_2B=$(human_size harness.js)
  RUNTIME_2B=$(du -sh node_modules 2>/dev/null | cut -f1)B

  node harness.js &
  LEG2B_PID=$!
  PIDS_TO_KILL+=("$LEG2B_PID")
  COLD_2B=$(cold_start_ms 5008)
  ok "cold start: ${COLD_2B}ms  app: $APP_2B  runtime: $RUNTIME_2B"

  HEY_2B=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5008/")
  RSS_2B_NODE=$(rss_mb "$LEG2B_PID")
  RSS_2B_CHROME=$(descendant_pids "$LEG2B_PID" | xargs -I{} ps -o rss= -p {} 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}')
  RSS_2B_CHROME=${RSS_2B_CHROME:-0}
  RSS_2B=$(( ${RSS_2B_NODE:-0} + RSS_2B_CHROME ))
  kill_and_wait "$LEG2B_PID"
  ok "hey done  rss: ${RSS_2B}MB (node:${RSS_2B_NODE}+chrome:${RSS_2B_CHROME})  p50: $(hey_stat "$HEY_2B" p50)ms  rps: $(hey_stat "$HEY_2B" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 2c: Pyodide / Chromium (Playwright)
# ══════════════════════════════════════════════════════════════════════════════
run_leg2c() {
  info "Leg 2c: Pyodide / Chromium Playwright (port 5009)"
  require_port_free 5009 "Leg 2c Pyodide/Playwright"

  pushd "$SCRIPT_DIR/leg2c_pyodide_playwright" >/dev/null
  export PLAYWRIGHT_BROWSERS_PATH=0
  if [ ! -d node_modules ]; then
    npm install --silent
    npx playwright install chromium
  fi
  APP_2C=$(human_size harness.js)
  RUNTIME_2C=$(du -sh node_modules 2>/dev/null | cut -f1)B

  node harness.js &
  LEG2C_PID=$!
  PIDS_TO_KILL+=("$LEG2C_PID")
  COLD_2C=$(cold_start_ms 5009)
  ok "cold start: ${COLD_2C}ms  app: $APP_2C  runtime: $RUNTIME_2C"

  HEY_2C=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5009/")
  RSS_2C_NODE=$(rss_mb "$LEG2C_PID")
  RSS_2C_CHROME=$(descendant_pids "$LEG2C_PID" | xargs -I{} ps -o rss= -p {} 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}')
  RSS_2C_CHROME=${RSS_2C_CHROME:-0}
  RSS_2C=$(( ${RSS_2C_NODE:-0} + RSS_2C_CHROME ))
  kill_and_wait "$LEG2C_PID"
  ok "hey done  rss: ${RSS_2C}MB (node:${RSS_2C_NODE}+chrome:${RSS_2C_CHROME})  p50: $(hey_stat "$HEY_2C" p50)ms  rps: $(hey_stat "$HEY_2C" rps)"
  unset PLAYWRIGHT_BROWSERS_PATH
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 3: Wasmtime
# ══════════════════════════════════════════════════════════════════════════════
run_leg3() {
  info "Leg 3: Wasmtime (port 5003)"
  require_port_free 5003 "Leg 3 Wasmtime"

  pushd "$EXPERIMENTS_DIR/shared/rust-hello" >/dev/null
  APP_3=$(human_size src/lib.rs)
  cargo build --target wasm32-wasip2 --release --quiet 2>&1
  WASM=$(find target/wasm32-wasip2/release -maxdepth 1 -name "*.wasm" | head -1)
  RUNTIME_3=$(du -sh "$WASM" | cut -f1)B

  wasmtime serve -S cli --addr "127.0.0.1:5003" "$WASM" &
  LEG3_PID=$!
  PIDS_TO_KILL+=("$LEG3_PID")
  COLD_3=$(cold_start_ms 5003)
  ok "cold start: ${COLD_3}ms  app: $APP_3  runtime: $RUNTIME_3"

  HEY_3=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5003/")
  RSS_3=$(rss_mb "$LEG3_PID")
  kill_and_wait "$LEG3_PID"
  ok "hey done  rss: ${RSS_3}MB  p50: $(hey_stat "$HEY_3" p50)ms  rps: $(hey_stat "$HEY_3" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# POSTGRES: shared database for legs 4a/4b/4c
# ══════════════════════════════════════════════════════════════════════════════
start_postgres() {
  info "Starting Postgres for legs 4a/4b/4c..."

  $CONTAINER_CMD rm -f bench-postgres &>/dev/null || true
  sleep 0.5
  require_port_free 5432 "Postgres"

  $CONTAINER_CMD run -d --name bench-postgres \
    -e POSTGRES_USER=bench \
    -e POSTGRES_PASSWORD=bench \
    -e POSTGRES_DB=bench \
    -p 5432:5432 \
    docker.io/library/postgres:16-alpine &>/dev/null

  for i in $(seq 1 50); do
    $CONTAINER_CMD exec bench-postgres psql -U bench -d bench -c '\q' &>/dev/null && break
    sleep 0.2
  done
  ok "Postgres ready"

  $CONTAINER_CMD cp "$SCRIPT_DIR/shared/postgres_init.sql" bench-postgres:/tmp/init.sql
  $CONTAINER_CMD exec bench-postgres psql -U bench -d bench -f /tmp/init.sql &>/dev/null
  ok "Database seeded"
}

stop_postgres() {
  $CONTAINER_CMD rm -f bench-postgres &>/dev/null
  ok "Postgres stopped"
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 4a: Flask + psycopg2 / direct Postgres
# ══════════════════════════════════════════════════════════════════════════════
run_leg4a() {
  info "Leg 4a: Flask + psycopg2 / direct (port 5004)"
  require_port_free 5004 "Leg 4a Flask+psycopg2"

  pushd "$SCRIPT_DIR/leg4a_flask_postgres" >/dev/null
  APP_4A=$(human_size app.py)
  if [ ! -d .venv ]; then
    python3 -m venv .venv
    .venv/bin/pip install --quiet 'flask==3.1.*' 'psycopg2-binary==2.9.*'
  fi
  RUNTIME_4A=$(du -sh .venv 2>/dev/null | cut -f1)B

  .venv/bin/python app.py &>/dev/null &
  LEG4A_PID=$!
  PIDS_TO_KILL+=("$LEG4A_PID")
  COLD_4A=$(cold_start_ms 5004 "/db?id=1")
  ok "cold start: ${COLD_4A}ms  app: $APP_4A  runtime: $RUNTIME_4A"

  HEY_4A=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5004/db?id=1")
  RSS_4A=$(rss_mb "$LEG4A_PID")
  kill_and_wait "$LEG4A_PID"
  ok "hey done  rss: ${RSS_4A}MB  p50: $(hey_stat "$HEY_4A" p50)ms  rps: $(hey_stat "$HEY_4A" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 4b: Node.js + Pyodide + pg bridge
# ══════════════════════════════════════════════════════════════════════════════
run_leg4b() {
  info "Leg 4b: Pyodide + pg bridge (port 5005)"
  require_port_free 5005 "Leg 4b Pyodide+pg"

  pushd "$SCRIPT_DIR/leg4b_wasm_postgres_bridge" >/dev/null
  [ -d node_modules ] || npm install --silent
  APP_4B=$(human_size harness.js)
  RUNTIME_4B=$(du -sh node_modules 2>/dev/null | cut -f1)B

  node harness.js &
  LEG4B_PID=$!
  PIDS_TO_KILL+=("$LEG4B_PID")
  COLD_4B=$(cold_start_ms 5005 "/db?id=1")
  ok "cold start: ${COLD_4B}ms  app: $APP_4B  runtime: $RUNTIME_4B"

  HEY_4B=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5005/db?id=1")
  RSS_4B=$(rss_mb "$LEG4B_PID")
  kill_and_wait "$LEG4B_PID"
  ok "hey done  rss: ${RSS_4B}MB  p50: $(hey_stat "$HEY_4B" p50)ms  rps: $(hey_stat "$HEY_4B" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 4c: Rust/Wasmtime + Node.js sidecar → Postgres
# ══════════════════════════════════════════════════════════════════════════════
run_leg4c() {
  info "Leg 4c: Wasmtime + sidecar (port 5006)"
  require_port_free 5006 "Leg 4c Wasmtime"
  require_port_free 5007 "Leg 4c sidecar"

  pushd "$SCRIPT_DIR/leg4c_wasmtime_postgres" >/dev/null
  [ -d node_modules ] || npm install --silent
  APP_4C=$(human_size src/lib.rs sidecar.js)
  cargo build --target wasm32-wasip2 --release --quiet 2>&1
  WASM_4C=$(find target/wasm32-wasip2/release -maxdepth 1 -name "*.wasm" | head -1)
  RUNTIME_4C="$(du -sh "$WASM_4C" | cut -f1)B+$(du -sh node_modules | cut -f1)B"

  node sidecar.js &
  SIDECAR_PID=$!
  PIDS_TO_KILL+=("$SIDECAR_PID")
  wait_for_http 5007 "/query?id=1" 5 "Sidecar"

  wasmtime serve -S cli -S inherit-network --addr "127.0.0.1:5006" "$WASM_4C" &
  LEG4C_PID=$!
  PIDS_TO_KILL+=("$LEG4C_PID")
  COLD_4C=$(cold_start_ms 5006 "/db?id=1")
  ok "cold start: ${COLD_4C}ms  app: $APP_4C  runtime: $RUNTIME_4C"

  HEY_4C=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5006/db?id=1")
  RSS_4C_WASM=$(rss_mb "$LEG4C_PID")
  RSS_4C_SIDE=$(rss_mb "$SIDECAR_PID")
  RSS_4C=$(( ${RSS_4C_WASM:-0} + ${RSS_4C_SIDE:-0} ))
  kill_and_wait "$LEG4C_PID"
  kill_and_wait "$SIDECAR_PID"
  ok "hey done  rss: ${RSS_4C}MB (wasm:${RSS_4C_WASM}+sidecar:${RSS_4C_SIDE})  p50: $(hey_stat "$HEY_4C" p50)ms  rps: $(hey_stat "$HEY_4C" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# Results table
# ══════════════════════════════════════════════════════════════════════════════
print_results() {
  echo ""
  echo "## Results — Hello World (legs 1–3, incl. 2a/2b/2c variants)"
  echo ""
  printf "| %-22s | %-20s | %-22s | %-22s | %-26s | %-16s |\n" "Metric" "Leg 1 Flask/Podman" "Leg 2a Pyodide/Node" "Leg 2b Pyodide/Chrome" "Leg 2c Pyodide/Playwright" "Leg 3 Wasmtime"
  printf "| %-22s | %-20s | %-22s | %-22s | %-26s | %-16s |\n" "---" "---" "---" "---" "---" "---"
  printf "| %-22s | %-20s | %-22s | %-22s | %-26s | %-16s |\n" "App code"             "${APP_1:-n/a}"                "${APP_2A:-n/a}"                "${APP_2B:-n/a}"                "${APP_2C:-n/a}"                    "${APP_3:-n/a}"
  printf "| %-22s | %-20s | %-22s | %-22s | %-26s | %-16s |\n" "Runtime/deps"         "${RUNTIME_1:-n/a}"            "${RUNTIME_2A:-n/a}"            "${RUNTIME_2B:-n/a}"            "${RUNTIME_2C:-n/a}"                "${RUNTIME_3:-n/a}"
  printf "| %-22s | %-20s | %-22s | %-22s | %-26s | %-16s |\n" "Cold start (ms)"      "${COLD_1:-n/a}"                "${COLD_2A:-n/a}"                "${COLD_2B:-n/a}"                "${COLD_2C:-n/a}"                    "${COLD_3:-n/a}"
  printf "| %-22s | %-20s | %-22s | %-22s | %-26s | %-16s |\n" "Memory RSS (MB)"      "${RSS_1:-n/a}"                 "${RSS_2A:-n/a}"                 "${RSS_2B:-n/a}"                 "${RSS_2C:-n/a}"                     "${RSS_3:-n/a}"
  printf "| %-22s | %-20s | %-22s | %-22s | %-26s | %-16s |\n" "hey p50 (ms)"         "$(hey_stat "${HEY_1:-}" p50)"  "$(hey_stat "${HEY_2A:-}" p50)"  "$(hey_stat "${HEY_2B:-}" p50)"  "$(hey_stat "${HEY_2C:-}" p50)"      "$(hey_stat "${HEY_3:-}" p50)"
  printf "| %-22s | %-20s | %-22s | %-22s | %-26s | %-16s |\n" "hey p99 (ms)"         "$(hey_stat "${HEY_1:-}" p99)"  "$(hey_stat "${HEY_2A:-}" p99)"  "$(hey_stat "${HEY_2B:-}" p99)"  "$(hey_stat "${HEY_2C:-}" p99)"      "$(hey_stat "${HEY_3:-}" p99)"
  printf "| %-22s | %-20s | %-22s | %-22s | %-26s | %-16s |\n" "hey req/s"            "$(hey_stat "${HEY_1:-}" rps)"  "$(hey_stat "${HEY_2A:-}" rps)"  "$(hey_stat "${HEY_2B:-}" rps)"  "$(hey_stat "${HEY_2C:-}" rps)"      "$(hey_stat "${HEY_3:-}" rps)"
  echo ""

  echo "## Results — Postgres DB query (legs 4a/4b/4c)"
  echo ""
  printf "| %-22s | %-24s | %-24s | %-24s |\n" "Metric" "Leg 4a Flask+psycopg2" "Leg 4b Pyodide+pg bridge" "Leg 4c Wasmtime+sidecar"
  printf "| %-22s | %-24s | %-24s | %-24s |\n" "---" "---" "---" "---"
  printf "| %-22s | %-24s | %-24s | %-24s |\n" "App code"             "${APP_4A:-n/a}"                  "${APP_4B:-n/a}"                  "${APP_4C:-n/a}"
  printf "| %-22s | %-24s | %-24s | %-24s |\n" "Runtime/deps"         "${RUNTIME_4A:-n/a}"              "${RUNTIME_4B:-n/a}"              "${RUNTIME_4C:-n/a}"
  printf "| %-22s | %-24s | %-24s | %-24s |\n" "Cold start (ms)"      "${COLD_4A:-n/a}"                  "${COLD_4B:-n/a}"                  "${COLD_4C:-n/a}"
  printf "| %-22s | %-24s | %-24s | %-24s |\n" "Memory RSS (MB)"      "${RSS_4A:-n/a}"                   "${RSS_4B:-n/a}"                   "${RSS_4C:-n/a}"
  printf "| %-22s | %-24s | %-24s | %-24s |\n" "hey p50 (ms)"         "$(hey_stat "${HEY_4A:-}" p50)"    "$(hey_stat "${HEY_4B:-}" p50)"    "$(hey_stat "${HEY_4C:-}" p50)"
  printf "| %-22s | %-24s | %-24s | %-24s |\n" "hey p99 (ms)"         "$(hey_stat "${HEY_4A:-}" p99)"    "$(hey_stat "${HEY_4B:-}" p99)"    "$(hey_stat "${HEY_4C:-}" p99)"
  printf "| %-22s | %-24s | %-24s | %-24s |\n" "hey req/s"            "$(hey_stat "${HEY_4A:-}" rps)"    "$(hey_stat "${HEY_4B:-}" rps)"    "$(hey_stat "${HEY_4C:-}" rps)"
  echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════"
echo "  Experiment 001 — Hello World Benchmark"
echo "════════════════════════════════════════════════"
echo ""

run_leg "Leg 1"  run_leg1
run_leg "Leg 2a" run_leg2a
run_leg "Leg 2b" run_leg2b
run_leg "Leg 2c" run_leg2c
run_leg "Leg 3"  run_leg3

run_leg "Postgres" start_postgres
run_leg "Leg 4a" run_leg4a
run_leg "Leg 4b" run_leg4b
run_leg "Leg 4c" run_leg4c
stop_postgres

print_results

# ── Report failures ──────────────────────────────────────────────────────────
if [ ${#FAILED_LEGS[@]} -gt 0 ]; then
  echo -e "${RED}Failed legs: ${FAILED_LEGS[*]}${NC}"
  exit 1
fi
