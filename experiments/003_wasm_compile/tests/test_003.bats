#!/usr/bin/env bats
# Experiment 003 — BATS tests
# Validates that each WASM HTTP leg returns valid JSON with expected shape.
#
# Prerequisites: all legs must already be built (make build) and running
# on their designated ports.  These tests are run by benchmark.sh inline;
# for standalone use start each leg manually first.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# ── Helper: fetch JSON from a running leg ─────────────────────────────────────
json_get() {
  local port=$1 path=${2:-/}
  curl -sf "http://127.0.0.1:${port}${path}"
}

# ── Source validation helper ──────────────────────────────────────────────────
valid_hello_json() {
  local json=$1
  echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'message' in d, 'missing message field'
assert d['message'] == 'Hello World', f'unexpected message: {d[\"message\"]}'
assert 'timestamp' in d, 'missing timestamp field'
assert isinstance(d['timestamp'], (int, float)), 'timestamp is not a number'
print('ok')
"
}

# ── Python source file smoke tests (no runtime required) ─────────────────────

@test "python-spin/app.py is syntactically valid Python" {
  python3 -m py_compile "$SCRIPT_DIR/python-spin/app.py"
}

@test "python-raw/app.py is syntactically valid Python" {
  python3 -m py_compile "$SCRIPT_DIR/python-raw/app.py"
}

# ── spin.toml presence ───────────────────────────────────────────────────────

@test "js-spin/spin.toml exists" {
  [ -f "$SCRIPT_DIR/js-spin/spin.toml" ]
}

@test "python-spin/spin.toml exists" {
  [ -f "$SCRIPT_DIR/python-spin/spin.toml" ]
}

# ── WIT interface ─────────────────────────────────────────────────────────────

@test "python-raw/wit/proxy.wit exists" {
  [ -f "$SCRIPT_DIR/python-raw/wit/proxy.wit" ]
}

# ── Runtime leg tests (skipped when ports not listening) ─────────────────────

@test "leg 1a JS/Spin native — returns Hello World JSON" {
  skip_if_no_port 5030
  result=$(json_get 5030)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "leg 1b JS/Spin podman — returns Hello World JSON" {
  skip_if_no_port 5031
  result=$(json_get 5031)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "leg 2a Python/raw wasmtime — returns Hello World JSON" {
  skip_if_no_port 5032
  result=$(json_get 5032)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "leg 2b Python/Spin native — returns Hello World JSON" {
  skip_if_no_port 5033
  result=$(json_get 5033)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "leg 2c Python/Spin podman — returns Hello World JSON" {
  skip_if_no_port 5034
  result=$(json_get 5034)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "leg 3 Rust/wasmtime baseline — returns Hello World JSON" {
  skip_if_no_port 5035
  result=$(json_get 5035)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

# ── Helper loaded after test definitions ──────────────────────────────────────
skip_if_no_port() {
  local port=$1
  if ! curl -sf --max-time 1 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
    skip "port ${port} not listening — start the leg first"
  fi
}
