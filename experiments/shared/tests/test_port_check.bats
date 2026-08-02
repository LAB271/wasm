#!/usr/bin/env bats
# Tests for require_port_free

setup() {
  source "$BATS_TEST_DIRNAME/../lib/bench.sh"
}

@test "require_port_free succeeds when port is free" {
  run require_port_free 59300 "free-port-test"
  [ "$status" -eq 0 ]
}

@test "require_port_free fails when port is occupied" {
  # Use nc (netcat) instead of Python — faster startup
  nc -l 59301 &
  listener_pid=$!
  sleep 0.1

  run require_port_free 59301 "occupied-port-test"
  kill "$listener_pid" 2>/dev/null || true

  [ "$status" -ne 0 ]
  [[ "$output" == *"already in use"* ]]
}

@test "require_port_free error message includes label" {
  nc -l 59302 &
  listener_pid=$!
  sleep 0.1

  run require_port_free 59302 "my-label"
  kill "$listener_pid" 2>/dev/null || true

  [ "$status" -ne 0 ]
  [[ "$output" == *"my-label"* ]]
}
