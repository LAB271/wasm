#!/usr/bin/env bash
# H4 check: `wasmtime run --profile=guest` against three zero-import builds
# (no_names / with_names / with_dwarf) that isolate whether the guest
# profiler needs the name section, DWARF, or neither to attribute samples to
# source-level function names instead of `<wasm function N>`.
#
# fibonacci(2_000_000_000) is a ~1s tight loop — long enough for the default
# 10ms sampling interval to collect dozens of samples on one hot function.
set -euo pipefail
cd "$(dirname "$0")/.."

N=2000000000
PROFILE_JSON=wasmtime-guest-profile.json

for f in output/profiling_no_names.wasm output/profiling_with_names.wasm output/profiling_with_dwarf.wasm; do
  echo "=== $f ==="
  rm -f "$PROFILE_JSON"
  wasmtime run --profile=guest -D debug-info=y --invoke fibonacci "$f" "$N" > /dev/null
  python3 -c "
import json
d = json.load(open('$PROFILE_JSON'))
th = d['threads'][0]
print('  resolved names in profile:', th['stringArray'])
print('  samples captured:', th['samples']['length'])
"
  rm -f "$PROFILE_JSON"
  echo
done
