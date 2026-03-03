#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()      { echo -e "  ${GREEN}✓${NC} $1"; }
missing() { echo -e "  ${RED}✗${NC} $1"; MISSING+=("$2"); }
warn()    { echo -e "  ${YELLOW}!${NC} $1"; }
info()    { echo -e "  ${YELLOW}→${NC} $1"; }

MISSING=()
INSTALL=false
START=false

usage() {
  echo "Usage: $0 [-i|--install] [-s|--start]"
  echo ""
  echo "  (default)      Check prerequisites and report what's missing"
  echo "  -i, --install  Install missing prerequisites via Homebrew"
  echo "  -s, --start    Start the Podman machine"
  echo ""
}

# --- Parse arguments ---
for arg in "$@"; do
  case $arg in
    -i|--install) INSTALL=true ;;
    -s|--start)   START=true ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

# --- Helpers ---

brew_install() {
  local pkg=$1
  if $INSTALL; then
    info "Installing $pkg..."
    brew install "$pkg"
  else
    missing "$pkg not found  →  brew install $pkg" "$pkg"
  fi
}

# --- Check/install functions ---

check_hey() {
  if command -v hey &>/dev/null; then
    ok "hey — $(hey --version 2>&1 | head -1)"
  else
    brew_install hey
  fi
}

check_container_runtime() {
  if command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
    ok "podman — $(podman --version)"
    CONTAINER_CMD="podman"
  elif command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    ok "docker — $(docker --version)"
    CONTAINER_CMD="docker"
  elif command -v podman &>/dev/null; then
    missing "podman installed but machine not running  →  ./install.sh --start" "container-runtime"
    CONTAINER_CMD=""
  else
    missing "no container runtime found  →  brew install podman" "container-runtime"
    CONTAINER_CMD=""
  fi
}

start_podman() {
  if ! command -v podman &>/dev/null; then
    echo -e "${RED}podman is not installed. Run: brew install podman${NC}"
    exit 1
  fi
  # Init machine if none exists yet (idempotent — skips if already initialised)
  if ! podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
    info "No podman machine found — initialising..."
    podman machine init
  else
    ok "podman machine already initialised"
  fi
  # Start if not already running
  if podman machine list --format '{{.Running}}' 2>/dev/null | grep -q "true"; then
    ok "podman machine already running"
  else
    info "Starting podman machine..."
    podman machine start
    ok "podman machine started"
  fi
}

check_wasmtime() {
  if command -v wasmtime &>/dev/null; then
    ok "wasmtime — $(wasmtime --version)"
  else
    brew_install wasmtime
  fi
}

check_rustup() {
  if rustup target list --installed 2>/dev/null | grep -q "wasm32-wasip2"; then
    ok "rust target wasm32-wasip2"
  elif command -v rustup &>/dev/null; then
    info "wasm32-wasip2 target missing — installing..."
    rustup target add wasm32-wasip2
    ok "rust target wasm32-wasip2 (just installed)"
  elif $INSTALL; then
    info "Installing rustup..."
    brew install rustup
    rustup-init -y
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
    rustup target add wasm32-wasip2
    ok "rustup + wasm32-wasip2 (just installed)"
  else
    missing "rustup not found  →  brew install rustup && rustup-init" "rustup"
  fi
}

check_node() {
  if command -v node &>/dev/null; then
    ok "node — $(node --version)"
  else
    brew_install node
  fi
}

check_npm() {
  if command -v npm &>/dev/null; then
    ok "npm — $(npm --version)"
  else
    missing "npm not found (ships with node)" "npm"
  fi
}

# --- Main ---

if $START; then
  echo ""
  start_podman
  echo ""
  exit 0
fi

echo ""
if $INSTALL; then
  echo "Installing prerequisites for wasm-experiments..."
else
  echo "Checking prerequisites for wasm-experiments..."
fi
echo ""

echo "Benchmark tools:"
check_hey

echo ""
echo "Container runtime:"
check_container_runtime

echo ""
echo "WASM tools:"
check_wasmtime
check_rustup

echo ""
echo "Node / Pyodide:"
check_node
check_npm

echo ""

if [ ${#MISSING[@]} -eq 0 ]; then
  echo -e "${GREEN}All prerequisites satisfied. You're ready to run experiments.${NC}"
  echo ""
else
  echo -e "${RED}Missing prerequisites:${NC}"
  for item in "${MISSING[@]}"; do
    echo "  - $item"
  done
  echo ""
  echo "Run ./install.sh --install to install them automatically."
  exit 1
fi
