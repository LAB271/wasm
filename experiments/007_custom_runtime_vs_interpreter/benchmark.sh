#!/usr/bin/env bash
# benchmark.sh — gathers artifact size, cold start, and a build-complexity
# metric for all three legs, directly rather than assuming experiment
# 001/003's own result tables are populated (they were blank as of this
# experiment being filed).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../001_hello_world/lib/bench.sh

EXPERIMENTS_ROOT="$(cd .. && pwd)"

echo "=========================================="
echo "Leg 1: custom_runtime"
echo "=========================================="
(cd custom_runtime/rust && cargo build --target wasm32-unknown-unknown --release >/dev/null)
CUSTOM_WASM="custom_runtime/rust/target/wasm32-unknown-unknown/release/custom_runtime_demo.wasm"
CUSTOM_SIZE=$(human_size "$CUSTOM_WASM")
CUSTOM_RESULT=$(cd custom_runtime/harness && node measure.mjs)
CUSTOM_OK=$(echo "$CUSTOM_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['ok'])")
CUSTOM_MS=$(echo "$CUSTOM_RESULT" | python3 -c "import json,sys; print(f\"{json.load(sys.stdin)['coldStartMs']:.2f}\")")
ok "custom_runtime: artifact=$CUSTOM_SIZE cold_start=${CUSTOM_MS}ms ok=$CUSTOM_OK"
CUSTOM_RUST_LINES=$(wc -l < custom_runtime/rust/src/lib.rs | tr -d ' ')
CUSTOM_JS_LINES=$(wc -l < custom_runtime/harness/runtime.js | tr -d ' ')

echo
echo "=========================================="
echo "Leg 2: componentize-py (reusing experiment 003's python-raw)"
echo "=========================================="
CPY_DIR="$EXPERIMENTS_ROOT/003_wasm_compile"
if [ ! -d "$CPY_DIR/.venv" ]; then
  info "Setting up venv + componentize-py..."
  python3 -m venv "$CPY_DIR/.venv"
  "$CPY_DIR/.venv/bin/pip" install --quiet -r "$CPY_DIR/requirements.txt"
fi
(cd "$CPY_DIR/python-raw" && ../.venv/bin/componentize-py -d wit -w proxy --all-features componentize app -o hello-py-raw.wasm >/dev/null)
CPY_WASM="$CPY_DIR/python-raw/hello-py-raw.wasm"
CPY_SIZE=$(human_size "$CPY_WASM")
ok "componentize-py: artifact=$CPY_SIZE (built successfully)"

CPY_COLD_START="N/A (see README)"
if command -v wasmtime &>/dev/null; then
  info "Attempting cold-start via wasmtime serve (known to fail in this environment — see README)..."
  wasmtime serve "$CPY_WASM" --addr 127.0.0.1:5032 >/tmp/exp007_cpy.log 2>&1 &
  CPY_PID=$!
  # cold_start_ms itself (fixed in this same experiment — see README "Finding")
  # now fails loudly rather than silently reporting a timeout as a real
  # number, so `|| true` here means "continue the benchmark," not "hide
  # the failure" — the failure is still reported via CPY_COLD_START.
  if CS=$(cold_start_ms 5032 / 10 2>&1); then
    CPY_COLD_START="${CS}ms"
    ok "componentize-py: cold_start=$CPY_COLD_START"
  else
    info "componentize-py cold start could not be measured — see /tmp/exp007_cpy.log"
    tail -5 /tmp/exp007_cpy.log || true
  fi
  kill_and_wait "$CPY_PID" 2>/dev/null || true
fi
CPY_WIT_LINES=$(wc -l < "$CPY_DIR/python-raw/wit/proxy.wit" | tr -d ' ')

echo
echo "=========================================="
echo "Leg 3: Pyodide (reusing experiment 001's leg2a_pyodide_node)"
echo "=========================================="
PYO_DIR="$EXPERIMENTS_ROOT/001_hello_world/leg2a_pyodide_node"
# No `|| true` here: if port 5002 is already held (e.g. a stray process from
# a previous run), continuing anyway means run.sh's own server fails to bind
# while curl happily talks to whatever *else* is on that port -- a fabricated
# "cold start" measurement of a process that never actually cold-started.
# Same failure shape as the cold_start_ms bug this experiment found and
# fixed (Finding 4); worth not repeating it one function away.
require_port_free 5002 "pyodide leg"
(cd "$PYO_DIR" && ./run.sh) >/tmp/exp007_pyodide.log 2>&1 &
PYO_PID=$!
PYO_CS=$(cold_start_ms 5002 / 15)
kill_and_wait "$PYO_PID"
pkill -f "node harness.js" 2>/dev/null || true
ok "Pyodide: cold_start=${PYO_CS}ms"
PYO_CORE_SIZE=$(human_size "$PYO_DIR/node_modules/pyodide/pyodide.asm.wasm" "$PYO_DIR/node_modules/pyodide/python_stdlib.zip")

echo
echo "## Results — experiment 007"
echo
echo "| Leg | Artifact size | Cold start | Hand-written runtime code | External toolchain |"
echo "|---|---|---|---|---|"
echo "| custom_runtime | $CUSTOM_SIZE | ${CUSTOM_MS}ms | ${CUSTOM_RUST_LINES} (rust) + ${CUSTOM_JS_LINES} (js) = $((CUSTOM_RUST_LINES + CUSTOM_JS_LINES)) lines | rustc + wasm32-unknown-unknown (stock) |"
echo "| componentize-py | $CPY_SIZE | $CPY_COLD_START | 0 lines (embeds CPython) | componentize-py + ${CPY_WIT_LINES}-line hand-authored WIT (+ ~3000 lines vendored WASI world defs, not hand-authored) |"
echo "| Pyodide | $PYO_CORE_SIZE (core .wasm + stdlib.zip) | ${PYO_CS}ms | 0 lines (embeds CPython) | npm \`pyodide\` package |"
