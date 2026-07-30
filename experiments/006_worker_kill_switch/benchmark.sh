#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../001_hello_world/lib/bench.sh

PORT=8899

info "Building..."
./build.sh >/dev/null

require_port_free "$PORT" "experiment 006 COI server"
python3 web/coi_server.py "$PORT" >/tmp/exp006_server.log 2>&1 &
SERVER_PID=$!
trap 'kill_and_wait "$SERVER_PID"' EXIT
wait_for_http "$PORT" "/index.html?variant=pure" 5 "COI server"

RESULTS=""
for variant in pure alloc; do
  info "Running harness for variant=$variant..."
  out=$(node harness.js "$variant" "http://127.0.0.1:$PORT")
  echo "  $out"

  died=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['diedWithinBudget'])")
  if [ "$died" != "True" ]; then
    fail "variant=$variant did not die within the poll budget — see raw output above"
    exit 1
  fi

  death_ms=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['deathAtMs'])")
  cpu_running=$(echo "$out" | python3 -c "import json,sys; print(f\"{json.load(sys.stdin)['cpuRunningPct']:.1f}\")")
  cpu_after=$(echo "$out" | python3 -c "import json,sys; print(f\"{json.load(sys.stdin)['cpuAfterDeathPct']:.1f}\")")
  ok "variant=$variant: died at t+${death_ms}ms, CPU running=${cpu_running}%, CPU after death=${cpu_after}%"
  RESULTS="${RESULTS}| $variant | ${death_ms}ms | ${cpu_running}% | ${cpu_after}% |\n"
done

echo
echo "## Results — experiment 006"
echo
echo "| Variant | Time to actual death (heartbeat-verified) | CPU%% while running | CPU%% after death |"
echo "|---|---|---|---|"
echo -e "$RESULTS"
