#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/bench.sh"

HEY_N=${HEY_N:-1000}
HEY_C=${HEY_C:-1}

command -v hey &>/dev/null || fail "hey not found — brew install hey"

CONTAINER_CMD=$(detect_container_cmd)

# ── Ensure dependencies ─────────────────────────────────────────────────────
pushd "$SCRIPT_DIR" >/dev/null
export PLAYWRIGHT_BROWSERS_PATH=0
if [ ! -d node_modules ]; then
  info "Installing dependencies..."
  npm install --silent
  npx playwright install chromium
fi
popd >/dev/null

# ── Cleanup trap ─────────────────────────────────────────────────────────────
PIDS_TO_KILL=()
cleanup() {
  for pid in "${PIDS_TO_KILL[@]}"; do
    kill_and_wait "$pid"
  done
  $CONTAINER_CMD rm -f bench-postgres 2>/dev/null || true
}
trap cleanup EXIT

# ── Per-leg failure tracking ─────────────────────────────────────────────────
FAILED_LEGS=()

run_leg() {
  local name=$1; shift
  if ! "$@"; then
    FAILED_LEGS+=("$name")
    echo -e "  ${RED}✗ $name FAILED${NC}" >&2
  fi
}

# ── Helper: RSS for harness (node + chrome tree) ────────────────────────────
harness_rss() {
  local pid=$1
  local node_rss chrome_rss
  node_rss=$(rss_mb "$pid")
  [[ "$node_rss" =~ ^[0-9]+$ ]] || node_rss=0
  chrome_rss=$(descendant_pids "$pid" | xargs -I{} ps -o rss= -p {} 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}')
  [[ "$chrome_rss" =~ ^[0-9]+$ ]] || chrome_rss=0
  echo "$(( node_rss + chrome_rss )):${node_rss}:${chrome_rss}"
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 1a: CPU-bound / shared page / sequential
# ══════════════════════════════════════════════════════════════════════════════
run_leg1a() {
  info "Leg 1a: CPU-bound / shared page (port 5010)"
  require_port_free 5010 "Leg 1a"

  node "$SCRIPT_DIR/harness.js" 1a &
  LEG1A_PID=$!
  PIDS_TO_KILL+=("$LEG1A_PID")
  COLD_1A=$(cold_start_ms 5010)
  ok "cold start: ${COLD_1A}ms"

  HEY_1A=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5010/")
  IFS=: read -r RSS_1A RSS_1A_NODE RSS_1A_CHROME <<< "$(harness_rss "$LEG1A_PID")"
  kill_and_wait "$LEG1A_PID"
  ok "rss: ${RSS_1A}MB (node:${RSS_1A_NODE}+chrome:${RSS_1A_CHROME})  p50: $(hey_stat "$HEY_1A" p50)ms  rps: $(hey_stat "$HEY_1A" rps)"
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 1b: CPU-bound / shared page / worker pool
# ══════════════════════════════════════════════════════════════════════════════
run_leg1b() {
  info "Leg 1b: CPU-bound / worker pool (port 5011)"
  require_port_free 5011 "Leg 1b"

  node "$SCRIPT_DIR/harness.js" 1b &
  LEG1B_PID=$!
  PIDS_TO_KILL+=("$LEG1B_PID")
  COLD_1B=$(cold_start_ms 5011)
  ok "cold start: ${COLD_1B}ms"

  HEY_1B=$(hey -n $HEY_N -c 5 "http://127.0.0.1:5011/")
  IFS=: read -r RSS_1B RSS_1B_NODE RSS_1B_CHROME <<< "$(harness_rss "$LEG1B_PID")"
  kill_and_wait "$LEG1B_PID"
  ok "rss: ${RSS_1B}MB (node:${RSS_1B_NODE}+chrome:${RSS_1B_CHROME})  p50: $(hey_stat "$HEY_1B" p50)ms  rps: $(hey_stat "$HEY_1B" rps)"
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 2a: JSON transform / shared page / sequential
# ══════════════════════════════════════════════════════════════════════════════
run_leg2a() {
  info "Leg 2a: JSON transform / shared page (port 5012)"
  require_port_free 5012 "Leg 2a"

  node "$SCRIPT_DIR/harness.js" 2a &
  LEG2A_PID=$!
  PIDS_TO_KILL+=("$LEG2A_PID")
  COLD_2A=$(cold_start_ms 5012)
  ok "cold start: ${COLD_2A}ms"

  HEY_2A=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5012/")
  IFS=: read -r RSS_2A RSS_2A_NODE RSS_2A_CHROME <<< "$(harness_rss "$LEG2A_PID")"
  kill_and_wait "$LEG2A_PID"
  ok "rss: ${RSS_2A}MB (node:${RSS_2A_NODE}+chrome:${RSS_2A_CHROME})  p50: $(hey_stat "$HEY_2A" p50)ms  rps: $(hey_stat "$HEY_2A" rps)"
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 2b: JSON transform / fresh BrowserContext / sequential
# ══════════════════════════════════════════════════════════════════════════════
run_leg2b() {
  info "Leg 2b: JSON transform / fresh context (port 5013)"
  require_port_free 5013 "Leg 2b"

  node "$SCRIPT_DIR/harness.js" 2b &
  LEG2B_PID=$!
  PIDS_TO_KILL+=("$LEG2B_PID")
  COLD_2B=$(cold_start_ms 5013)
  ok "cold start: ${COLD_2B}ms"

  HEY_2B=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5013/")
  IFS=: read -r RSS_2B RSS_2B_NODE RSS_2B_CHROME <<< "$(harness_rss "$LEG2B_PID")"
  kill_and_wait "$LEG2B_PID"
  ok "rss: ${RSS_2B}MB (node:${RSS_2B_NODE}+chrome:${RSS_2B_CHROME})  p50: $(hey_stat "$HEY_2B" p50)ms  rps: $(hey_stat "$HEY_2B" rps)"
}

# ══════════════════════════════════════════════════════════════════════════════
# POSTGRES: shared database for legs 3a/3b/4a/4b
# ══════════════════════════════════════════════════════════════════════════════
start_postgres() {
  info "Starting Postgres for legs 3a/3b/4a/4b..."

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
# LEG 3a: DB query / shared page / sequential
# ══════════════════════════════════════════════════════════════════════════════
run_leg3a() {
  info "Leg 3a: DB query / shared page (port 5014)"
  require_port_free 5014 "Leg 3a"

  node "$SCRIPT_DIR/harness.js" 3a &
  LEG3A_PID=$!
  PIDS_TO_KILL+=("$LEG3A_PID")
  COLD_3A=$(cold_start_ms 5014 "/db?id=1")
  ok "cold start: ${COLD_3A}ms"

  HEY_3A=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5014/db?id=1")
  IFS=: read -r RSS_3A RSS_3A_NODE RSS_3A_CHROME <<< "$(harness_rss "$LEG3A_PID")"
  kill_and_wait "$LEG3A_PID"
  ok "rss: ${RSS_3A}MB (node:${RSS_3A_NODE}+chrome:${RSS_3A_CHROME})  p50: $(hey_stat "$HEY_3A" p50)ms  rps: $(hey_stat "$HEY_3A" rps)"
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 3b: DB query / fresh BrowserContext / sequential
# ══════════════════════════════════════════════════════════════════════════════
run_leg3b() {
  info "Leg 3b: DB query / fresh context (port 5015)"
  require_port_free 5015 "Leg 3b"

  node "$SCRIPT_DIR/harness.js" 3b &
  LEG3B_PID=$!
  PIDS_TO_KILL+=("$LEG3B_PID")
  COLD_3B=$(cold_start_ms 5015 "/db?id=1")
  ok "cold start: ${COLD_3B}ms"

  HEY_3B=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5015/db?id=1")
  IFS=: read -r RSS_3B RSS_3B_NODE RSS_3B_CHROME <<< "$(harness_rss "$LEG3B_PID")"
  kill_and_wait "$LEG3B_PID"
  ok "rss: ${RSS_3B}MB (node:${RSS_3B_NODE}+chrome:${RSS_3B_CHROME})  p50: $(hey_stat "$HEY_3B" p50)ms  rps: $(hey_stat "$HEY_3B" rps)"
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 4a: Mixed / shared page / sequential
# ══════════════════════════════════════════════════════════════════════════════
run_leg4a() {
  info "Leg 4a: Mixed / shared page (port 5016)"
  require_port_free 5016 "Leg 4a"

  node "$SCRIPT_DIR/harness.js" 4a &
  LEG4A_PID=$!
  PIDS_TO_KILL+=("$LEG4A_PID")
  COLD_4A=$(cold_start_ms 5016 "/db?id=1")
  ok "cold start: ${COLD_4A}ms"

  HEY_4A=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5016/db?id=1")
  IFS=: read -r RSS_4A RSS_4A_NODE RSS_4A_CHROME <<< "$(harness_rss "$LEG4A_PID")"
  kill_and_wait "$LEG4A_PID"
  ok "rss: ${RSS_4A}MB (node:${RSS_4A_NODE}+chrome:${RSS_4A_CHROME})  p50: $(hey_stat "$HEY_4A" p50)ms  rps: $(hey_stat "$HEY_4A" rps)"
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 4b: Mixed / BrowserContext pool / concurrent
# ══════════════════════════════════════════════════════════════════════════════
run_leg4b() {
  info "Leg 4b: Mixed / context pool (port 5017)"
  require_port_free 5017 "Leg 4b"

  node "$SCRIPT_DIR/harness.js" 4b &
  LEG4B_PID=$!
  PIDS_TO_KILL+=("$LEG4B_PID")
  COLD_4B=$(cold_start_ms 5017 "/db?id=1")
  ok "cold start: ${COLD_4B}ms"

  HEY_4B=$(hey -n $HEY_N -c 5 "http://127.0.0.1:5017/db?id=1")
  IFS=: read -r RSS_4B RSS_4B_NODE RSS_4B_CHROME <<< "$(harness_rss "$LEG4B_PID")"
  kill_and_wait "$LEG4B_PID"
  ok "rss: ${RSS_4B}MB (node:${RSS_4B_NODE}+chrome:${RSS_4B_CHROME})  p50: $(hey_stat "$HEY_4B" p50)ms  rps: $(hey_stat "$HEY_4B" rps)"
}

# ══════════════════════════════════════════════════════════════════════════════
# Results tables
# ══════════════════════════════════════════════════════════════════════════════
print_results() {
  echo ""
  echo "## Results — CPU-bound workload (legs 1a/1b)"
  echo ""
  printf "| %-22s | %-24s | %-24s |\n" "Metric" "1a Shared/Sequential" "1b Worker Pool (c=5)"
  printf "| %-22s | %-24s | %-24s |\n" "---" "---" "---"
  printf "| %-22s | %-24s | %-24s |\n" "Cold start (ms)"   "${COLD_1A:-n/a}" "${COLD_1B:-n/a}"
  printf "| %-22s | %-24s | %-24s |\n" "Memory RSS (MB)"   "${RSS_1A:-n/a}"  "${RSS_1B:-n/a}"
  printf "| %-22s | %-24s | %-24s |\n" "hey p50 (ms)" "$(hey_stat "${HEY_1A:-}" p50)" "$(hey_stat "${HEY_1B:-}" p50)"
  printf "| %-22s | %-24s | %-24s |\n" "hey p99 (ms)" "$(hey_stat "${HEY_1A:-}" p99)" "$(hey_stat "${HEY_1B:-}" p99)"
  printf "| %-22s | %-24s | %-24s |\n" "hey req/s"    "$(hey_stat "${HEY_1A:-}" rps)" "$(hey_stat "${HEY_1B:-}" rps)"
  echo ""

  echo "## Results — JSON transform (legs 2a/2b)"
  echo ""
  printf "| %-22s | %-24s | %-28s |\n" "Metric" "2a Shared/Sequential" "2b Fresh Context/Sequential"
  printf "| %-22s | %-24s | %-28s |\n" "---" "---" "---"
  printf "| %-22s | %-24s | %-28s |\n" "Cold start (ms)"   "${COLD_2A:-n/a}" "${COLD_2B:-n/a}"
  printf "| %-22s | %-24s | %-28s |\n" "Memory RSS (MB)"   "${RSS_2A:-n/a}"  "${RSS_2B:-n/a}"
  printf "| %-22s | %-24s | %-28s |\n" "hey p50 (ms)" "$(hey_stat "${HEY_2A:-}" p50)" "$(hey_stat "${HEY_2B:-}" p50)"
  printf "| %-22s | %-24s | %-28s |\n" "hey p99 (ms)" "$(hey_stat "${HEY_2A:-}" p99)" "$(hey_stat "${HEY_2B:-}" p99)"
  printf "| %-22s | %-24s | %-28s |\n" "hey req/s"    "$(hey_stat "${HEY_2A:-}" rps)" "$(hey_stat "${HEY_2B:-}" rps)"
  echo ""

  echo "## Results — DB query (legs 3a/3b)"
  echo ""
  printf "| %-22s | %-24s | %-28s |\n" "Metric" "3a Shared/Sequential" "3b Fresh Context/Sequential"
  printf "| %-22s | %-24s | %-28s |\n" "---" "---" "---"
  printf "| %-22s | %-24s | %-28s |\n" "Cold start (ms)"   "${COLD_3A:-n/a}" "${COLD_3B:-n/a}"
  printf "| %-22s | %-24s | %-28s |\n" "Memory RSS (MB)"   "${RSS_3A:-n/a}"  "${RSS_3B:-n/a}"
  printf "| %-22s | %-24s | %-28s |\n" "hey p50 (ms)" "$(hey_stat "${HEY_3A:-}" p50)" "$(hey_stat "${HEY_3B:-}" p50)"
  printf "| %-22s | %-24s | %-28s |\n" "hey p99 (ms)" "$(hey_stat "${HEY_3A:-}" p99)" "$(hey_stat "${HEY_3B:-}" p99)"
  printf "| %-22s | %-24s | %-28s |\n" "hey req/s"    "$(hey_stat "${HEY_3A:-}" rps)" "$(hey_stat "${HEY_3B:-}" rps)"
  echo ""

  echo "## Results — Mixed workload (legs 4a/4b)"
  echo ""
  printf "| %-22s | %-24s | %-28s |\n" "Metric" "4a Shared/Sequential" "4b Context Pool (c=5)"
  printf "| %-22s | %-24s | %-28s |\n" "---" "---" "---"
  printf "| %-22s | %-24s | %-28s |\n" "Cold start (ms)"   "${COLD_4A:-n/a}" "${COLD_4B:-n/a}"
  printf "| %-22s | %-24s | %-28s |\n" "Memory RSS (MB)"   "${RSS_4A:-n/a}"  "${RSS_4B:-n/a}"
  printf "| %-22s | %-24s | %-28s |\n" "hey p50 (ms)" "$(hey_stat "${HEY_4A:-}" p50)" "$(hey_stat "${HEY_4B:-}" p50)"
  printf "| %-22s | %-24s | %-28s |\n" "hey p99 (ms)" "$(hey_stat "${HEY_4A:-}" p99)" "$(hey_stat "${HEY_4B:-}" p99)"
  printf "| %-22s | %-24s | %-28s |\n" "hey req/s"    "$(hey_stat "${HEY_4A:-}" rps)" "$(hey_stat "${HEY_4B:-}" rps)"
  echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════"
echo "  Experiment 002 — Chromium Sandbox Benchmark"
echo "════════════════════════════════════════════════"
echo ""

# Non-DB legs
run_leg "Leg 1a" run_leg1a
run_leg "Leg 1b" run_leg1b
run_leg "Leg 2a" run_leg2a
run_leg "Leg 2b" run_leg2b

# DB legs
run_leg "Postgres" start_postgres
run_leg "Leg 3a" run_leg3a
run_leg "Leg 3b" run_leg3b
run_leg "Leg 4a" run_leg4a
run_leg "Leg 4b" run_leg4b
stop_postgres

print_results

# ── Report failures ──────────────────────────────────────────────────────────
if [ ${#FAILED_LEGS[@]} -gt 0 ]; then
  echo -e "${RED}Failed legs: ${FAILED_LEGS[*]}${NC}"
  exit 1
fi
