#!/usr/bin/env bash
# Re-validation for issue #52.
#
# The in-process rematch measures six variants sequentially, and #52 established
# that whichever runs first is ~1.3x faster regardless of what it is. Here each
# variant gets its OWN node process — there is no "first" for the bias to favour
# — and the sweep repeats so process-to-process noise stays visible.
#
# No associative arrays: macOS /bin/bash is 3.2. Results go to a file and awk
# does the aggregation.
set -uo pipefail
cd "$(dirname "$0")"

REPS=${REPS:-3}
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

VARIANTS=("WASM -Oz" "WASM -O3" "js naive (4 allocs/call)" "js tuned switch (010's figure)" "js bit-packed nibbles" "js typed-array scratch")

echo "one variant per process, ${REPS} independent processes each, median of 7 timed rounds within each"
echo ""
for rep in $(seq 1 "$REPS"); do
    for v in "${VARIANTS[@]}"; do
        med=$(node js/bench_010_rematch.mjs --only "$v" 2>/dev/null | grep '^RESULT|' | cut -d'|' -f3)
        if [ -z "$med" ]; then printf '  rep%s  %-32s   FAILED\n' "$rep" "$v"; continue; fi
        printf '%s\t%s\n' "$v" "$med" >> "$OUT"
        printf '  rep%s  %-32s %8s ms\n' "$rep" "$v" "$med"
    done
    echo ""
done

awk -F'\t' -v reps="$REPS" '
{ if (!($1 in best) || $2+0 < best[$1]) best[$1] = $2+0 }
END {
    printf "=== best-of-%d, each in an isolated process ===\n", reps
    printf "  %-32s %10s\n", "VARIANT", "median ms"
    wasm = 1e9; js = 1e9; jsname = "?"
    for (v in best) {
        printf "  %-32s %10.4f\n", v, best[v]
        if (v ~ /^WASM/) { if (best[v] < wasm) wasm = best[v] }
        else            { if (best[v] < js)  { js = best[v]; jsname = v } }
    }
    printf "\n  best WASM      : %.4f ms\n", wasm
    printf "  best JS        : %.4f ms  (%s)\n", js, jsname
    printf "  ratio JS/WASM  : %.2fx   (>1 means WASM faster, <1 means JS faster)\n", js/wasm
}' "$OUT"
