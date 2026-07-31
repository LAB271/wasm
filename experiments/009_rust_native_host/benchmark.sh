#!/usr/bin/env bash
# benchmark.sh — two measurements, kept deliberately separate rather than
# collapsed into one number:
#   1. True cold start: OS process launch -> compile -> instantiate -> call
#      -> exit, measured externally (the shell's `time`, not the program's
#      own clock, which only starts after the OS has already loaded and
#      exec'd the binary).
#   2. The article's own methodology: compile once, then loop N times over
#      fresh Store+Instance+call+drop, all inside one already-running
#      process — reproduced faithfully so its number is checkable.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "→ Building..."
./build.sh >/dev/null

BIN=./host/target/release/wasm_host

echo
echo "=== True cold start (external wall-clock, includes OS process launch) ==="
echo "First invocation of this freshly-built binary:"
{ time "$BIN" --single-shot ; } 2>&1
echo
echo "Second invocation (OS file cache now warm from the first run):"
{ time "$BIN" --single-shot ; } 2>&1

echo
echo "=== Warm-loop benchmark (article's own methodology: compile once, loop N) ==="
"$BIN" --loop 1000
