#!/usr/bin/env bash
# H1 check: for each tier, validate the module and list which custom sections
# (name / DWARF) survive, then run llvm-dwarfdump --verify on any tier that
# claims to carry DWARF. All output here is real tool output, not summarized.
set -euo pipefail
cd "$(dirname "$0")/.."

declare -A TIERS=(
  [tier1_fully_optimized]="output/tier1_fully_optimized.wasm"
  [tier2_optimized_names]="output/tier2_optimized_names.wasm"
  [tier3_release_debuginfo]="output/tier3_release_debuginfo.wasm"
  [tier4_full_debug]="output/tier4_full_debug.wasm"
)

for name in tier1_fully_optimized tier2_optimized_names tier3_release_debuginfo tier4_full_debug; do
  f="${TIERS[$name]}"
  echo "=== $name ($f) ==="
  echo -n "  wasm-tools validate: "
  wasm-tools validate "$f" && echo OK
  echo "  custom sections:"
  sections=$(wasm-tools objdump "$f" 2>&1 | grep -i custom || true)
  if [ -z "$sections" ]; then
    echo "    (none)"
  else
    echo "$sections" | sed 's/^/    /'
  fi
  if echo "$sections" | grep -q debug_info; then
    echo "  llvm-dwarfdump --verify:"
    llvm-dwarfdump --verify "$f" 2>&1 | tail -3 | sed 's/^/    /'
  fi
  echo
done
