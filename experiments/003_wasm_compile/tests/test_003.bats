#!/usr/bin/env bats
# Experiment 003 — BATS tests
# Validates sources, build artifacts, and runtime legs.
#
# Build artifacts:
#   build/hello-js-spin.wasm   — JS compiled via Spin          (legs 1a, 1b)
#   build/hello-py-raw.wasm    — Python compiled via componentize-py (leg 2a)
#   build/hello-py-spin.wasm   — Python compiled via Spin       (legs 2b, 2c)
#   build/hello-rust.wasm      — Rust compiled via cargo        (leg 3)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GIT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PYTHON="uv run --directory $GIT_ROOT python"
BUILD_DIR="$SCRIPT_DIR/build"

# ── Helper: fetch JSON from a running leg ─────────────────────────────────────
json_get() {
  local port=$1 path=${2:-/}
  curl -sf "http://127.0.0.1:${port}${path}"
}

# ── Source validation helper ──────────────────────────────────────────────────
valid_hello_json() {
  local json=$1
  echo "$json" | $PYTHON -c "
import sys, json
d = json.load(sys.stdin)
assert 'message' in d, 'missing message field'
assert d['message'] == 'Hello World', f'unexpected message: {d[\"message\"]}'
assert 'timestamp' in d, 'missing timestamp field'
assert isinstance(d['timestamp'], (int, float)), 'timestamp is not a number'
print('ok')
"
}

# ── Helper: skip if port not listening ────────────────────────────────────────
skip_if_no_port() {
  local port=$1
  if ! curl -sf --max-time 1 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
    skip "port ${port} not listening — start the leg first"
  fi
}

# ── Source checks (no build required) ─────────────────────────────────────────

@test "source: python-spin/app.py is valid Python" {
  $PYTHON -m py_compile "$SCRIPT_DIR/python-spin/app.py"
}

@test "source: python-raw/app.py is valid Python" {
  $PYTHON -m py_compile "$SCRIPT_DIR/python-raw/app.py"
}

@test "source: js-spin/spin.toml exists" {
  [ -f "$SCRIPT_DIR/js-spin/spin.toml" ]
}

@test "source: python-spin/spin.toml exists" {
  [ -f "$SCRIPT_DIR/python-spin/spin.toml" ]
}

@test "source: python-raw/wit/proxy.wit exists" {
  [ -f "$SCRIPT_DIR/python-raw/wit/proxy.wit" ]
}

# ── Build artifact checks (require: make build) ──────────────────────────────

@test "build: hello-js-spin.wasm exists" {
  [ -f "$BUILD_DIR/hello-js-spin.wasm" ]
}

@test "build: hello-py-raw.wasm exists" {
  [ -f "$BUILD_DIR/hello-py-raw.wasm" ]
}

@test "build: hello-py-spin.wasm exists" {
  [ -f "$BUILD_DIR/hello-py-spin.wasm" ]
}

@test "build: hello-rust.wasm exists" {
  [ -f "$BUILD_DIR/hello-rust.wasm" ]
}

# ── Runtime leg tests (skipped when ports not listening) ──────────────────────

@test "leg 1a: JS/Spin native (port 5030) — returns Hello World JSON" {
  skip_if_no_port 5030
  result=$(json_get 5030)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "leg 1b: JS/Spin podman (port 5031) — returns Hello World JSON" {
  skip_if_no_port 5031
  result=$(json_get 5031)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "leg 2a: Python/raw wasmtime (port 5032) — returns Hello World JSON" {
  skip_if_no_port 5032
  result=$(json_get 5032)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "leg 2b: Python/Spin native (port 5033) — returns Hello World JSON" {
  skip_if_no_port 5033
  result=$(json_get 5033)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "leg 2c: Python/Spin podman (port 5034) — returns Hello World JSON" {
  skip_if_no_port 5034
  result=$(json_get 5034)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "leg 3: Rust/wasmtime baseline (port 5035) — returns Hello World JSON" {
  skip_if_no_port 5035
  result=$(json_get 5035)
  [ "$(valid_hello_json "$result")" = "ok" ]
}
