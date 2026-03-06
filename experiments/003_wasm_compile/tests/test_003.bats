#!/usr/bin/env bats
# Experiment 003 — BATS tests
# Validates sources, build artifacts, and runtime legs.
#
# Naming: NNN_component — phase: description
#
# Build artifacts (in build/):
#   hello-js-spin.wasm   — JS compiled via Spin              (legs 1a, 1b)
#   hello-py-raw.wasm    — Python compiled via componentize-py (leg 2a)
#   hello-py-spin.wasm   — Python compiled via Spin           (legs 2b, 2c)
#   hello-rust.wasm      — Rust compiled via cargo            (leg 3)
#   hello-as.wasm        — AssemblyScript via asc + wasm-tools (leg 4)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GIT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PYTHON="uv run --directory $GIT_ROOT python"
BUILD_DIR="$SCRIPT_DIR/build"

# ── Helpers ───────────────────────────────────────────────────────────────────

json_get() {
  local port=$1 path=${2:-/}
  curl -sf "http://127.0.0.1:${port}${path}"
}

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

skip_if_no_port() {
  local port=$1
  if ! curl -sf --max-time 1 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
    skip "port ${port} not listening — start the leg first"
  fi
}

# ── js-spin ───────────────────────────────────────────────────────────────────

@test "001_js-spin — source: spin.toml exists" {
  [ -f "$SCRIPT_DIR/js-spin/spin.toml" ]
}

@test "002_js-spin — build: hello-js-spin.wasm exists" {
  [ -f "$BUILD_DIR/hello-js-spin.wasm" ]
}

@test "003_js-spin — leg 1a: native (port 5030) returns Hello World JSON" {
  skip_if_no_port 5030
  result=$(json_get 5030)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "004_js-spin — leg 1b: podman (port 5031) returns Hello World JSON" {
  skip_if_no_port 5031
  result=$(json_get 5031)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

# ── py-raw ────────────────────────────────────────────────────────────────────

@test "005_py-raw — source: app.py is valid Python" {
  $PYTHON -m py_compile "$SCRIPT_DIR/python-raw/app.py"
}

@test "006_py-raw — source: wit/proxy.wit exists" {
  [ -f "$SCRIPT_DIR/python-raw/wit/proxy.wit" ]
}

@test "007_py-raw — build: hello-py-raw.wasm exists" {
  [ -f "$BUILD_DIR/hello-py-raw.wasm" ]
}

@test "008_py-raw — leg 2a: wasmtime (port 5032) returns Hello World JSON" {
  skip_if_no_port 5032
  result=$(json_get 5032)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

# ── py-spin ───────────────────────────────────────────────────────────────────

@test "009_py-spin — source: app.py is valid Python" {
  $PYTHON -m py_compile "$SCRIPT_DIR/python-spin/app.py"
}

@test "010_py-spin — source: spin.toml exists" {
  [ -f "$SCRIPT_DIR/python-spin/spin.toml" ]
}

@test "011_py-spin — build: hello-py-spin.wasm exists" {
  [ -f "$BUILD_DIR/hello-py-spin.wasm" ]
}

@test "012_py-spin — leg 2b: native (port 5033) returns Hello World JSON" {
  skip_if_no_port 5033
  result=$(json_get 5033)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

@test "013_py-spin — leg 2c: podman (port 5034) returns Hello World JSON" {
  skip_if_no_port 5034
  result=$(json_get 5034)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

# ── rust ──────────────────────────────────────────────────────────────────────

@test "014_rust — build: hello-rust.wasm exists" {
  [ -f "$BUILD_DIR/hello-rust.wasm" ]
}

@test "015_rust — leg 3: wasmtime (port 5035) returns Hello World JSON" {
  skip_if_no_port 5035
  result=$(json_get 5035)
  [ "$(valid_hello_json "$result")" = "ok" ]
}

# ── as-hello ──────────────────────────────────────────────────────────────────

@test "016_as — source: assembly/index.ts exists" {
  [ -f "$SCRIPT_DIR/as-hello/assembly/index.ts" ]
}

@test "017_as — source: build.sh is executable" {
  [ -x "$SCRIPT_DIR/as-hello/build.sh" ]
}

@test "018_as — build: hello-as.wasm exists" {
  [ -f "$BUILD_DIR/hello-as.wasm" ]
}

@test "019_as — leg 4: wasmtime (port 5036) returns Hello World JSON" {
  skip_if_no_port 5036
  result=$(json_get 5036)
  [ "$(valid_hello_json "$result")" = "ok" ]
}
