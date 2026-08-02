#!/bin/bash
# Run every (leg, op) cell and write JSONL to results/.
#
# Benchmark hygiene (issue #52): each cell runs in ITS OWN FRESH PROCESS, so no
# two variants are ever compared inside one process and there is no tier-up
# budget to compete over. On top of that, `./run.sh both` runs the whole matrix
# in forward leg order and again in reverse leg order; `make report` prints both
# side by side so the reader can see the ordering makes no difference.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-forward}"      # forward | reverse | both
ROUNDS="${ROUNDS:-9}"
WARMUP="${WARMUP:-3}"
HOST=host/target/release/collections_host

mkdir -p results

# leg:op pairs. Not every strategy applies to every collection; a missing pair
# is a finding, not an omission, and the README says which and why.
CELLS=(
  "wat:callcost"            "wat:str"            "wat:list"
  "wat:map_sorted"          "wat:set_bitset"     "wat:set_sorted"

  "rust_manual:callcost"    "rust_manual:str"    "rust_manual:list"
  "rust_manual:map_sorted"  "rust_manual:map_hash" "rust_manual:map_handle"
  "rust_manual:set_bitset"  "rust_manual:set_sorted" "rust_manual:set_hash"

  "assemblyscript:callcost" "assemblyscript:str" "assemblyscript:list"
  "assemblyscript:map_sorted" "assemblyscript:map_hash"
  "assemblyscript:set_bitset" "assemblyscript:set_sorted" "assemblyscript:set_hash"

  "component:callcost"      "component:callcost_list" "component:str" "component:list"
  "component:map_sorted"    "component:set_bitset" "component:set_sorted"

  "externref:str"           "externref:list"
  "externref:map_host"      "externref:set_host"
)

# wasm-bindgen emits a JS module, so its cells run under Node, not wasmtime.
JS_CELLS=( "callcost" "str" "list" "map" "set_bitset" "set_sorted" )

run_pass() {
  local order="$1" out="results/$1.jsonl"
  : > "$out"
  local cells=("${CELLS[@]}")
  if [ "$order" = "reverse" ]; then
    local rev=(); for ((i=${#cells[@]}-1; i>=0; i--)); do rev+=("${cells[i]}"); done
    cells=("${rev[@]}")
  fi
  # Burn-in. The first recorded pass showed wat's cells 1.15-1.55x slower than
  # the same cells at the end of the reverse pass -- a machine-level warm-up
  # effect (CPU frequency ramp / page cache), NOT the in-process tier-up bias
  # from issue #52, since every cell already runs in its own process. Three
  # discarded cells removes it; the ordering table proves it.
  for _ in 1 2 3; do
    ( cd host && ./target/release/collections_host --leg rust_manual --op list \
        --rounds 3 --warmup 1 --json ) > /dev/null 2>&1 || true
  done
  echo "--- pass: $order (${#cells[@]} wasmtime cells + ${#JS_CELLS[@]} node cells) ---"
  for cell in "${cells[@]}"; do
    local leg="${cell%%:*}" op="${cell##*:}"
    printf "  %-16s %-12s " "$leg" "$op"
    if ( cd host && ./target/release/collections_host \
           --leg "$leg" --op "$op" --rounds "$ROUNDS" --warmup "$WARMUP" --json ) >> "$out" 2>/tmp/020.err
    then echo "ok"
    else echo "FAILED"; sed 's/^/      /' /tmp/020.err; exit 1
    fi
  done
  local js=("${JS_CELLS[@]}")
  if [ "$order" = "reverse" ]; then
    local rev=(); for ((i=${#js[@]}-1; i>=0; i--)); do rev+=("${js[i]}"); done
    js=("${rev[@]}")
  fi
  for op in "${js[@]}"; do
    printf "  %-16s %-12s " "rust_bindgen" "$op"
    if node js/bench_bindgen.mjs "$op" >> "$out" 2>/tmp/020.err
    then echo "ok"
    else echo "FAILED"; sed 's/^/      /' /tmp/020.err; exit 1
    fi
  done
}

[ -x "$HOST" ] || { echo "host not built — run ./build.sh first"; exit 1; }

case "$MODE" in
  forward) run_pass forward ;;
  reverse) run_pass reverse ;;
  both)    run_pass forward; run_pass reverse ;;
  *) echo "usage: $0 [forward|reverse|both]"; exit 1 ;;
esac

echo ""
echo "results written to results/"
