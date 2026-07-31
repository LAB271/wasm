#!/usr/bin/env bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$ROOT_DIR/experiments"

PASSED=()
FAILED=()
SKIPPED=()

usage() {
  echo "Usage: $0 [experiment...]"
  echo ""
  echo "  (default)      Run 'make test' in every experiments/*/ that has a Makefile"
  echo "  experiment...  Only run the named experiment directories (e.g. 001_hello_world)"
  echo ""
}

for arg in "$@"; do
  case $arg in
    -h|--help) usage; exit 0 ;;
  esac
done

if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=()
  for dir in "$EXPERIMENTS_DIR"/*/; do
    TARGETS+=("$(basename "$dir")")
  done
fi

echo "Running tests for ${#TARGETS[@]} experiment(s)..."
echo ""

for name in "${TARGETS[@]}"; do
  dir="$EXPERIMENTS_DIR/$name"

  if [ ! -d "$dir" ]; then
    echo -e "  ${RED}✗${NC} $name — directory not found"
    SKIPPED+=("$name (not found)")
    continue
  fi

  if [ ! -f "$dir/Makefile" ]; then
    echo -e "  ${YELLOW}→${NC} $name — no Makefile, skipping"
    SKIPPED+=("$name (no Makefile)")
    continue
  fi

  if ! grep -q '^test:' "$dir/Makefile"; then
    echo -e "  ${YELLOW}→${NC} $name — no 'test' target, skipping"
    SKIPPED+=("$name (no test target)")
    continue
  fi

  echo -e "${YELLOW}=== $name ===${NC}"
  if (cd "$dir" && make test); then
    echo -e "  ${GREEN}✓${NC} $name"
    PASSED+=("$name")
  else
    echo -e "  ${RED}✗${NC} $name"
    FAILED+=("$name")
  fi
  echo ""
done

echo "─────────────────────────────────────────"
echo -e "${GREEN}Passed:${NC}  ${#PASSED[@]}"
echo -e "${RED}Failed:${NC}  ${#FAILED[@]}"
echo -e "${YELLOW}Skipped:${NC} ${#SKIPPED[@]}"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo -e "${RED}Failed experiments:${NC}"
  for item in "${FAILED[@]}"; do
    echo "  - $item"
  done
  exit 1
fi
