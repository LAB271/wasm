#!/usr/bin/env bats
# Unit tests for lib/bench.sh helper functions

setup() {
  source "$BATS_TEST_DIRNAME/../lib/bench.sh"
}

# ── now_ms ────────────────────────────────────────────────────────────────────

@test "now_ms returns a 13-digit number" {
  result=$(now_ms)
  [[ "$result" =~ ^[0-9]{13}$ ]]
}

@test "now_ms increases over time" {
  t1=$(now_ms)
  sleep 0.05
  t2=$(now_ms)
  [ "$t2" -gt "$t1" ]
}

# ── rss_mb ────────────────────────────────────────────────────────────────────

@test "rss_mb returns a number for current shell PID" {
  result=$(rss_mb $$)
  [[ "$result" =~ ^[0-9]+$ ]]
  [ "$result" -gt 0 ]
}

@test "rss_mb returns ? for invalid PID" {
  result=$(rss_mb 999999999)
  [ "$result" = "?" ]
}

# ── hey_stat ──────────────────────────────────────────────────────────────────

@test "hey_stat extracts p50 from sample output" {
  sample='  50%% in 0.0012 secs'
  result=$(hey_stat "$sample" p50)
  [ "$result" = "1.2" ]
}

@test "hey_stat extracts p99 from sample output" {
  sample='  99%% in 0.0089 secs'
  result=$(hey_stat "$sample" p99)
  [ "$result" = "8.9" ]
}

@test "hey_stat extracts rps from sample output" {
  sample='  Requests/sec:	1234.5678'
  result=$(hey_stat "$sample" rps)
  [ "$result" = "1235" ]
}

# ── require_port_free ─────────────────────────────────────────────────────────

@test "require_port_free succeeds on a free port" {
  run require_port_free 59123 "test"
  [ "$status" -eq 0 ]
}

@test "require_port_free fails when port is occupied" {
  # Start a listener on a high port
  python3 -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 59124))
s.listen(1)
time.sleep(10)
" &
  listener_pid=$!
  sleep 0.3
  run require_port_free 59124 "test"
  kill "$listener_pid" 2>/dev/null; wait "$listener_pid" 2>/dev/null || true
  [ "$status" -ne 0 ]
}

# ── detect_container_cmd ──────────────────────────────────────────────────────

@test "detect_container_cmd respects CONTAINER_CMD override" {
  CONTAINER_CMD="fake-docker" run detect_container_cmd
  [ "$output" = "fake-docker" ]
}

@test "detect_container_cmd returns podman or docker" {
  unset CONTAINER_CMD
  result=$(detect_container_cmd 2>/dev/null) || true
  if [ -n "$result" ]; then
    [[ "$result" = "podman" || "$result" = "docker" ]]
  else
    skip "No container runtime available"
  fi
}

# ── descendant_pids ───────────────────────────────────────────────────────────

@test "descendant_pids returns child PIDs" {
  # Spawn a child that spawns a grandchild
  bash -c 'sleep 30 & wait' &
  parent=$!
  sleep 0.3
  result=$(descendant_pids "$parent")
  kill "$parent" 2>/dev/null; wait "$parent" 2>/dev/null || true
  # Should find at least one descendant (the sleep process)
  [ -n "$result" ]
}

# ── human_size ────────────────────────────────────────────────────────────────

@test "human_size formats bytes for small files" {
  tmp=$(mktemp)
  echo -n "hello" > "$tmp"  # 5 bytes
  result=$(human_size "$tmp")
  rm -f "$tmp"
  [ "$result" = "5B" ]
}

@test "human_size sums multiple files" {
  tmp1=$(mktemp); tmp2=$(mktemp)
  dd if=/dev/zero of="$tmp1" bs=512 count=1 2>/dev/null
  dd if=/dev/zero of="$tmp2" bs=512 count=1 2>/dev/null
  result=$(human_size "$tmp1" "$tmp2")
  rm -f "$tmp1" "$tmp2"
  [ "$result" = "1.0KB" ]
}

# ── output helpers ────────────────────────────────────────────────────────────

@test "ok outputs green checkmark" {
  result=$(ok "test message")
  [[ "$result" == *"✓"* ]]
  [[ "$result" == *"test message"* ]]
}

@test "info outputs yellow arrow" {
  result=$(info "test message")
  [[ "$result" == *"→"* ]]
  [[ "$result" == *"test message"* ]]
}

@test "fail returns 1 and outputs red X" {
  run fail "test error"
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗"* ]]
  [[ "$output" == *"test error"* ]]
}
