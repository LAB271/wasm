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
  python3 -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 59301))
s.listen(1)
time.sleep(10)
" &
  listener_pid=$!
  sleep 0.3

  run require_port_free 59301 "occupied-port-test"
  kill "$listener_pid" 2>/dev/null; wait "$listener_pid" 2>/dev/null || true

  [ "$status" -ne 0 ]
  [[ "$output" == *"already in use"* ]]
}

@test "require_port_free error message includes label" {
  python3 -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 59302))
s.listen(1)
time.sleep(10)
" &
  listener_pid=$!
  sleep 0.3

  run require_port_free 59302 "my-label"
  kill "$listener_pid" 2>/dev/null; wait "$listener_pid" 2>/dev/null || true

  [ "$status" -ne 0 ]
  [[ "$output" == *"my-label"* ]]
}
