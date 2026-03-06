#!/usr/bin/env bats
# Tests for cold_start_ms and wait_for_http

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/bench.sh"
}

teardown() {
  # Clean up any background server
  if [ -n "${server_pid:-}" ]; then
    kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null || true
  fi
}

@test "cold_start_ms returns a positive integer for a running server" {
  python3 -m http.server 59200 &>/dev/null &
  server_pid=$!
  sleep 0.3

  result=$(cold_start_ms 59200 / 5)
  kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null || true

  [[ "$result" =~ ^[0-9]+$ ]]
  [ "$result" -ge 0 ]
}

@test "wait_for_http succeeds for a running server" {
  python3 -m http.server 59201 &>/dev/null &
  server_pid=$!
  sleep 0.3

  run wait_for_http 59201 / 5 "test-server"
  kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null || true

  [ "$status" -eq 0 ]
}

@test "wait_for_http times out on non-existent port" {
  run wait_for_http 59299 / 1 "ghost-server"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not become ready"* ]]
}
