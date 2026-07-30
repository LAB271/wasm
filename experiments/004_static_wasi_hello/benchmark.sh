#!/usr/bin/env bash
# benchmark.sh — cold-start + artifact-size measurement for experiment 004.
#
# Cold start here means: page navigation start -> WASI program's stdout
# fully captured and the page's own "done" signal set. There is no server
# process to launch first (that's the whole point of this experiment) — a
# trivial static file server just serves already-built static files, so
# unlike experiments 001-003 there is no process-launch time to measure on
# top of the page load itself.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../001_hello_world/lib/bench.sh

PORT=8899
RUNS="${RUNS:-10}"

info "Building (compile + vendor shim)..."
./build.sh >/dev/null

require_port_free "$PORT" "experiment 004 static server"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory web >/tmp/exp004_server.log 2>&1 &
SERVER_PID=$!
trap 'kill_and_wait "$SERVER_PID"' EXIT
wait_for_http "$PORT" "/index.html" 5 "static server"

info "Running $RUNS cold-start measurements..."
declare -a TIMES=()
for i in $(seq 1 "$RUNS"); do
  out=$(cd web && node measure.mjs "http://127.0.0.1:$PORT")
  ok=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['ok'])")
  if [ "$ok" != "True" ]; then
    fail "run $i did not produce the expected output: $out"
    exit 1
  fi
  ms=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['coldStartMs'])")
  TIMES+=("$ms")
  echo "  run $i: ${ms}ms"
done

STATS=$(printf '%s\n' "${TIMES[@]}" | python3 -c "
import sys, statistics
vals = [float(l) for l in sys.stdin]
vals.sort()
print(f'min={vals[0]:.1f} median={statistics.median(vals):.1f} max={vals[-1]:.1f}')
")
ok "cold start ($RUNS runs): $STATS ms"

WASM_SIZE=$(human_size web/hello_wasi.wasm)
PAGE_TOTAL=$(human_size web/index.html web/worker.js web/hello_wasi.wasm web/vendor/browser_wasi_shim/*.js)
ok "artifact size (.wasm only): $WASM_SIZE"
ok "total page weight (html+js+wasm): $PAGE_TOTAL"

echo
echo "## Results — experiment 004"
echo
echo "| Metric | Value |"
echo "|---|---|"
echo "| Cold start, $RUNS runs (min/median/max, ms) | $STATS |"
echo "| Artifact size (.wasm only) | $WASM_SIZE |"
echo "| Total page weight (html+js+wasm, no bundler) | $PAGE_TOTAL |"
echo "| Requires a running process at view time? | No — static files only |"
