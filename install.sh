#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()      { echo -e "  ${GREEN}✓${NC} $1"; }
missing() { echo -e "  ${RED}✗${NC} $1  →  $2"; MISSING+=("$1"); }
info()    { echo -e "  ${YELLOW}→${NC} $1"; }

MISSING=()
INSTALL=false
START=false
CONTAINER_CMD=""
NEEDS_RELOAD=false
CARGO_BIN="${CARGO_HOME:-$HOME/.cargo}/bin"

usage() {
  echo "Usage: $0 [-i|--install] [-s|--start]"
  echo ""
  echo "  (default)      Check prerequisites and report what's missing"
  echo "  -i, --install  Install missing prerequisites via Homebrew"
  echo "  -s, --start    Start the Podman machine"
  echo ""
}

for arg in "$@"; do
  case $arg in
    -i|--install) INSTALL=true ;;
    -s|--start)   START=true ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

# ── Checks (pure: return 0 = found, 1 = not found) ──────────────────────────

have_hey()            { command -v hey &>/dev/null; }
have_podman()         { command -v podman &>/dev/null; }
have_docker()         { command -v docker &>/dev/null; }
have_podman_running() { podman info &>/dev/null 2>&1; }
have_docker_running() { docker info &>/dev/null 2>&1; }
have_wasmtime()       { command -v wasmtime &>/dev/null; }
have_rustup()         { command -v rustup &>/dev/null; }
have_rust_default()   { rustup toolchain list 2>&1 | grep -q "default"; }
have_wasm_target()    { rustup target list --installed 2>&1 | grep -q "wasm32-wasip2"; }
have_cargo()          { command -v cargo &>/dev/null; }
have_node()           { command -v node &>/dev/null; }
have_npm()            { command -v npm &>/dev/null; }

# ── Installers (pure: install only, no checks or reporting) ─────────────────

install_hey()         { brew install hey; }
install_wasmtime()    { brew install wasmtime; }
source_cargo_env() {
  local cargo_env="${CARGO_HOME:-$HOME/.cargo}/env"
  # shellcheck source=/dev/null
  [ -f "$cargo_env" ] && source "$cargo_env"
}
install_rustup() {
  brew install rustup
  rustup-init -y --no-modify-path
  source_cargo_env
  NEEDS_RELOAD=true
}
install_cargo_shims() {
  rustup-init -y --no-modify-path
  source_cargo_env
  NEEDS_RELOAD=true
}
install_rust_default() { rustup default stable; }
install_wasm_target()  { rustup target add wasm32-wasip2; }
install_node()         { brew install node; }

install_all_missing() {
  have_hey          || { info "Installing hey...";                  install_hey; }
  have_wasmtime     || { info "Installing wasmtime...";             install_wasmtime; }
  have_rustup       || { info "Installing rustup...";               install_rustup; }
  have_cargo        || { info "Creating cargo shims...";            install_cargo_shims; }
  have_rust_default || { info "Setting default Rust toolchain...";  install_rust_default; }
  have_wasm_target  || { info "Adding wasm32-wasip2 target...";     install_wasm_target; }
  have_node         || { info "Installing node...";                 install_node; }
}

# ── Reporters (check state, print ok/missing, populate MISSING[]) ────────────

report_hey() {
  if have_hey; then
    ok "hey"
  else
    missing "hey" "brew install hey"
  fi
}

report_container_runtime() {
  if have_podman && have_podman_running; then
    ok "podman — $(podman --version)"
    CONTAINER_CMD=podman
  elif have_docker && have_docker_running; then
    ok "docker — $(docker --version)"
    CONTAINER_CMD=docker
  elif have_podman; then
    missing "podman (machine not running)" "./install.sh --start"
    CONTAINER_CMD=""
  else
    missing "container runtime" "brew install podman"
    CONTAINER_CMD=""
  fi
}

report_wasmtime() {
  if have_wasmtime; then
    ok "wasmtime — $(wasmtime --version)"
  else
    missing "wasmtime" "brew install wasmtime"
  fi
}

report_rustup() {
  if ! have_rustup; then
    missing "rustup" "brew install rustup && rustup-init -y"
    return
  fi
  if ! have_cargo; then
    missing "cargo shims" "rustup-init -y && source ~/.bashrc"
    return
  fi
  if ! have_rust_default; then
    missing "rust default toolchain" "rustup default stable"
    return
  fi
  if have_wasm_target; then
    ok "cargo — $(cargo --version 2>&1)"
    ok "rust target wasm32-wasip2"
  else
    missing "rust target wasm32-wasip2" "rustup target add wasm32-wasip2"
  fi
}

report_node() {
  if have_node; then
    ok "node — $(node --version)"
  else
    missing "node" "brew install node"
  fi
}

report_npm() {
  if have_npm; then
    ok "npm — $(npm --version)"
  else
    missing "npm (ships with node)" "brew install node"
  fi
}

report_all() {
  echo "Benchmark tools:"
  report_hey

  echo ""
  echo "Container runtime:"
  report_container_runtime

  echo ""
  echo "WASM tools:"
  report_wasmtime
  report_rustup

  echo ""
  echo "Node / Pyodide:"
  report_node
  report_npm
}

# ── Podman machine ───────────────────────────────────────────────────────────

start_podman() {
  if ! have_podman; then
    echo -e "${RED}podman is not installed. Run: brew install podman${NC}"
    exit 1
  fi
  if ! podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
    info "No podman machine found — initialising..."
    podman machine init
  else
    ok "podman machine already initialised"
  fi
  if podman machine list --format '{{.Running}}' 2>/dev/null | grep -q "true"; then
    ok "podman machine already running"
  else
    info "Starting podman machine..."
    podman machine start
    ok "podman machine started"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

if $START; then
  echo ""
  start_podman
  echo ""
  exit 0
fi

echo ""
if $INSTALL; then
  echo "Installing prerequisites for wasm-experiments..."
  echo ""
  install_all_missing
  echo ""
  echo "Verifying..."
else
  echo "Checking prerequisites for wasm-experiments..."
fi
echo ""

report_all
echo ""

if $NEEDS_RELOAD; then
  echo -e "${YELLOW}!${NC} Shell PATH was updated. Reload with:"
  echo ""
  echo "  source ~/.bashrc && echo \"Reloaded ~/.bashrc\""
  echo ""
fi

if [ ${#MISSING[@]} -eq 0 ]; then
  echo -e "${GREEN}All prerequisites satisfied. You're ready to run experiments.${NC}"
  echo ""
else
  echo -e "${RED}Missing prerequisites:${NC}"
  for item in "${MISSING[@]}"; do
    echo "  - $item"
  done
  echo ""
  if ! $INSTALL; then
    echo "Run ./install.sh --install to install them automatically."
  fi
  exit 1
fi
