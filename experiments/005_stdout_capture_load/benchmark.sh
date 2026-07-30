#!/usr/bin/env bash
# benchmark.sh — runs the full N x dom matrix and reports timing + correctness.
#
# Each measurement launches a fresh headless Chromium instance (Playwright's
# chromium.launch() per invocation of measure.mjs) — there is no shared warm
# browser across the matrix. That's a deliberate limitation, not an oversight:
# see README "Methodology" for what this does and doesn't let you compare.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../001_hello_world/lib/bench.sh

PORT=8899
NS=(10 1000 100000)
DOMS=(1 0)
TIMEOUT_MS=60000

info "Building..."
./build.sh >/dev/null

require_port_free "$PORT" "experiment 005 static server"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory web >/tmp/exp005_server.log 2>&1 &
SERVER_PID=$!
trap 'kill_and_wait "$SERVER_PID"' EXIT
wait_for_http "$PORT" "/index.html?n=1&dom=0" 5 "static server"

echo
printf "%-8s %-5s %-9s %-14s %-16s %-10s\n" "N" "dom" "ok" "worker(ms)" "mainThread(ms)" "lines"
printf "%-8s %-5s %-9s %-14s %-16s %-10s\n" "-" "---" "--" "----------" "--------------" "-----"

RESULTS=""
for n in "${NS[@]}"; do
  for dom in "${DOMS[@]}"; do
    out=$(cd web && node measure.mjs "http://127.0.0.1:$PORT" "$n" "$dom" "$TIMEOUT_MS")
    ok=$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ok'))")
    timed_out=$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('timedOut', False))")
    if [ "$timed_out" = "True" ]; then
      printf "%-8s %-5s %-9s %-14s %-16s %-10s\n" "$n" "$dom" "TIMEOUT" "-" "-" "-"
      RESULTS="${RESULTS}| $n | $dom | **timed out (>${TIMEOUT_MS}ms)** | | | |\n"
      continue
    fi
    worker_ms=$(echo "$out" | python3 -c "import json,sys; print(f\"{json.load(sys.stdin)['workerElapsedMs']:.1f}\")")
    main_ms=$(echo "$out" | python3 -c "import json,sys; print(f\"{json.load(sys.stdin)['mainThreadElapsedMs']:.1f}\")")
    total_lines=$(( n * 2 ))
    printf "%-8s %-5s %-9s %-14s %-16s %-10s\n" "$n" "$dom" "$ok" "$worker_ms" "$main_ms" "$total_lines"
    if [ "$ok" != "True" ]; then
      fail "N=$n dom=$dom did not verify: $out"
      exit 1
    fi
    RESULTS="${RESULTS}| $n | $dom | $total_lines | $worker_ms | $main_ms |\n"
  done
done

echo
ok "all correctness checks passed (per-stream monotonic sequence, exact counts, no console errors)"
echo
echo "## Results — experiment 005"
echo
echo "| N (lines/stream) | dom | total lines | worker-side (ms) | main-thread total (ms) |"
echo "|---|---|---|---|---|"
echo -e "$RESULTS"
