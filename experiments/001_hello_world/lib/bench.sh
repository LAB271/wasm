#!/usr/bin/env bash
# bench.sh — shared helper library for benchmark.sh and tests
# Source this file; do not execute directly.

# ── Output helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1" >&2; return 1; }

# ── ERR trap: print file:line on failure ──────────────────────────────────────
setup_err_trap() {
  trap '_bench_err_handler $LINENO "${BASH_SOURCE[0]}"' ERR
}
_bench_err_handler() {
  echo -e "  ${RED}✗ ERROR at ${2}:${1}${NC}" >&2
}

# ── Detect container runtime ─────────────────────────────────────────────────
detect_container_cmd() {
  if [ -n "${CONTAINER_CMD:-}" ]; then
    echo "$CONTAINER_CMD"
    return
  fi
  if command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
    echo "podman"
  elif command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    echo "docker"
  else
    fail "No running container runtime (podman or docker). Run: ./install.sh --start"
  fi
}

# ── Milliseconds since epoch (macOS-safe) ─────────────────────────────────────
now_ms() { python3 -c "import time; print(int(time.time()*1000))"; }

# ── Cold-start measurement ───────────────────────────────────────────────────
# Usage: cold_start_ms <port> [path] [timeout_seconds]
cold_start_ms() {
  local port=$1 path=${2:-/} timeout=${3:-10}
  local start end iterations
  iterations=$(( timeout * 10 ))  # 0.1s per iteration
  start=$(now_ms)
  for i in $(seq 1 "$iterations"); do
    curl -sf "http://127.0.0.1:$port$path" &>/dev/null && break
    sleep 0.1
  done
  end=$(now_ms)
  echo $(( end - start ))
}

# ── RSS in MB ─────────────────────────────────────────────────────────────────
rss_mb() {
  local pid=$1 rss
  rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0f", $1/1024}')
  if [ -z "$rss" ]; then
    echo "?"
  else
    echo "$rss"
  fi
}

# ── Parse hey output ──────────────────────────────────────────────────────────
hey_stat() {
  local out=$1 stat=$2 val
  case "$stat" in
    p50) val=$(echo "$out" | grep "50%%" | awk '{printf "%.1f", $3*1000}') ;;
    p95) val=$(echo "$out" | grep "95%%" | awk '{printf "%.1f", $3*1000}') ;;
    p99) val=$(echo "$out" | grep "99%%" | awk '{printf "%.1f", $3*1000}') ;;
    rps) val=$(echo "$out" | grep "Requests/sec:" | awk '{printf "%.0f", $2}') ;;
  esac
  echo "${val:-n/a}"
}

# ── Descendant PIDs (recursive) ──────────────────────────────────────────────
descendant_pids() {
  local parent=$1
  for child in $(pgrep -P "$parent" 2>/dev/null); do
    echo "$child"
    descendant_pids "$child"
  done
}

# ── Pre-flight port check ────────────────────────────────────────────────────
require_port_free() {
  local port=$1 label=${2:-port $1}
  if lsof -i :"$port" &>/dev/null; then
    fail "Port $port already in use ($label) — free it first"
  fi
}

# ── Safe process teardown ────────────────────────────────────────────────────
kill_and_wait() {
  local pid=$1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# ── Bounded HTTP readiness check ─────────────────────────────────────────────
# Usage: wait_for_http <port> <path> [timeout_seconds] [label]
wait_for_http() {
  local port=$1 path=$2 timeout=${3:-10} label=${4:-port $1}
  local iterations=$(( timeout * 10 ))
  for i in $(seq 1 "$iterations"); do
    curl -sf "http://127.0.0.1:$port$path" &>/dev/null && return 0
    sleep 0.1
  done
  fail "$label did not become ready on port $port within ${timeout}s"
}

# ── Human-readable file size ─────────────────────────────────────────────────
# Usage: human_size <file_or_dir> ...
# Sums the byte sizes of all arguments and formats as B/KB/MB
human_size() {
  local total=0
  for path in "$@"; do
    if [ -f "$path" ]; then
      total=$(( total + $(wc -c < "$path") ))
    fi
  done
  if [ "$total" -ge 1048576 ]; then
    awk "BEGIN{printf \"%.1fMB\", $total/1048576}"
  elif [ "$total" -ge 1024 ]; then
    awk "BEGIN{printf \"%.1fKB\", $total/1024}"
  else
    echo "${total}B"
  fi
}
