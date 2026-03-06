#!/usr/bin/env bash
# Experiment 003 — JS, Python, AS to .wasm benchmark
# Legs: 1a (JS/Spin native), 1b (JS/Spin podman), 2a (Python/raw wasmtime),
#       2b (Python/Spin native), 2c (Python/Spin podman), 3 (Rust baseline),
#       4 (AssemblyScript/wasmtime)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/bench.sh"

HEY_N=${HEY_N:-1000}
HEY_C=${HEY_C:-1}

# Ensure Rust/cargo is on PATH
export PATH="${CARGO_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/cargo}/bin:$PATH"

# Activate local venv so componentize-py is available without a global install
if [ -f "$SCRIPT_DIR/.venv/bin/activate" ]; then
  source "$SCRIPT_DIR/.venv/bin/activate"
fi

command -v hey             &>/dev/null || fail "hey not found — brew install hey"
command -v spin            &>/dev/null || fail "spin not found — brew install fermyon/tap/spin"
command -v wasmtime        &>/dev/null || fail "wasmtime not found — brew install wasmtime"
command -v componentize-py &>/dev/null || fail "componentize-py not found — run: make deps"
command -v wasm-tools      &>/dev/null || fail "wasm-tools not found — cargo install wasm-tools"

CONTAINER_CMD=$(detect_container_cmd)

# ── Cleanup trap ──────────────────────────────────────────────────────────────
PIDS_TO_KILL=()
CONTAINERS_TO_KILL=()

cleanup() {
  for pid in "${PIDS_TO_KILL[@]:-}"; do
    kill_and_wait "$pid" 2>/dev/null || true
  done
  for ctr in "${CONTAINERS_TO_KILL[@]:-}"; do
    $CONTAINER_CMD rm -f "$ctr" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ── Per-leg failure tracking ──────────────────────────────────────────────────
FAILED_LEGS=()

run_leg() {
  local name=$1; shift
  if ! "$@"; then
    FAILED_LEGS+=("$name")
    echo -e "  ${RED}✗ $name FAILED${NC}" >&2
  fi
}

# ── Build helper ──────────────────────────────────────────────────────────────
# Measures build time in ms; outputs result to BUILD_TIME variable.
timed_build() {
  local label=$1; shift
  local t0; t0=$(now_ms)
  "$@"
  echo $(( $(now_ms) - t0 ))
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 1a: JavaScript → Spin (native macOS)
# ══════════════════════════════════════════════════════════════════════════════
run_leg1a() {
  info "Leg 1a: JS/Spin native macOS (port 5030)"
  require_port_free 5030 "Leg 1a"

  pushd "$SCRIPT_DIR/js-spin" >/dev/null
    APP_1A=$(human_size src/index.js)
    npm ci --silent 2>/dev/null || npm install --silent
    BUILD_1A=$(timed_build "spin build" spin build --quiet 2>/dev/null)
    WASM_1A=$(find dist -name "*.wasm" -maxdepth 1 | head -1)
    ARTIFACT_1A=$(human_size "$WASM_1A")
    RUNTIME_1A="spin $(spin --version 2>&1 | head -1 | awk '{print $NF}')"

    spin up --listen "127.0.0.1:5030" &>/dev/null &
    SPIN_1A_PID=$!
    PIDS_TO_KILL+=("$SPIN_1A_PID")
    COLD_1A=$(cold_start_ms 5030)
    ok "cold start: ${COLD_1A}ms  app: $APP_1A  artifact: $ARTIFACT_1A  build: ${BUILD_1A}ms"

    HEY_1A=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5030/")
    RSS_1A=$(rss_mb "$SPIN_1A_PID")
    kill_and_wait "$SPIN_1A_PID"
    PIDS_TO_KILL=("${PIDS_TO_KILL[@]/$SPIN_1A_PID}")
    ok "hey done  rss: ${RSS_1A}MB  p50: $(hey_stat "$HEY_1A" p50)ms  p95: $(hey_stat "$HEY_1A" p95)ms  rps: $(hey_stat "$HEY_1A" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 1b: JavaScript → Spin (Spin-in-podman)
# ══════════════════════════════════════════════════════════════════════════════
run_leg1b() {
  info "Leg 1b: JS/Spin podman (port 5031)"
  require_port_free 5031 "Leg 1b"

  pushd "$SCRIPT_DIR" >/dev/null
    # Ensure JS is built first
    [ -n "${ARTIFACT_1A:-}" ] || { pushd js-spin >/dev/null; spin build --quiet 2>/dev/null; popd >/dev/null; }
    WASM_JS=$(find js-spin/dist -name "*.wasm" -maxdepth 1 | head -1)

    $CONTAINER_CMD build -t hello-js-spin \
      --build-arg APP_DIR=js-spin \
      --build-arg WASM_SRC="${WASM_JS#js-spin/}" \
      --build-arg WASM_DST="${WASM_JS#js-spin/}" \
      -f Containerfile . &>/dev/null
    RUNTIME_1B=$($CONTAINER_CMD image inspect hello-js-spin --format '{{.Size}}' \
      | awk '{printf "%.0fMB", $1/1048576}')

    $CONTAINER_CMD run -d --name bench-js-spin -p 5031:3000 hello-js-spin &>/dev/null
    CONTAINERS_TO_KILL+=("bench-js-spin")

    CTR_PID=$($CONTAINER_CMD inspect --format '{{.State.Pid}}' bench-js-spin 2>/dev/null || echo 0)
    COLD_1B=$(cold_start_ms 5031)
    APP_1B="${APP_1A:-n/a}"
    ARTIFACT_1B="${ARTIFACT_1A:-n/a}"
    ok "cold start: ${COLD_1B}ms  image: $RUNTIME_1B"

    HEY_1B=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5031/")
    RSS_1B=$(rss_mb "$CTR_PID")
    $CONTAINER_CMD rm -f bench-js-spin &>/dev/null
    CONTAINERS_TO_KILL=("${CONTAINERS_TO_KILL[@]/bench-js-spin}")
    ok "hey done  rss: ${RSS_1B}MB  p50: $(hey_stat "$HEY_1B" p50)ms  p95: $(hey_stat "$HEY_1B" p95)ms  rps: $(hey_stat "$HEY_1B" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 2a: Python → componentize-py → wasmtime serve (native macOS)
# ══════════════════════════════════════════════════════════════════════════════
run_leg2a() {
  info "Leg 2a: Python/componentize-py + wasmtime serve (port 5032)"
  require_port_free 5032 "Leg 2a"

  pushd "$SCRIPT_DIR/python-raw" >/dev/null
    APP_2A=$(human_size app.py)
    BUILD_2A=$(timed_build "componentize-py" \
      componentize-py -d wit -w proxy componentize app -o hello-py-raw.wasm 2>/dev/null)
    ARTIFACT_2A=$(human_size hello-py-raw.wasm)
    RUNTIME_2A="wasmtime $(wasmtime --version | awk '{print $2}')"

    wasmtime serve -S cli hello-py-raw.wasm --addr "127.0.0.1:5032" &>/dev/null &
    WM_2A_PID=$!
    PIDS_TO_KILL+=("$WM_2A_PID")
    COLD_2A=$(cold_start_ms 5032)
    ok "cold start: ${COLD_2A}ms  app: $APP_2A  artifact: $ARTIFACT_2A  build: ${BUILD_2A}ms"

    HEY_2A=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5032/")
    RSS_2A=$(rss_mb "$WM_2A_PID")
    kill_and_wait "$WM_2A_PID"
    PIDS_TO_KILL=("${PIDS_TO_KILL[@]/$WM_2A_PID}")
    ok "hey done  rss: ${RSS_2A}MB  p50: $(hey_stat "$HEY_2A" p50)ms  p95: $(hey_stat "$HEY_2A" p95)ms  rps: $(hey_stat "$HEY_2A" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 2b: Python → Spin (native macOS)
# ══════════════════════════════════════════════════════════════════════════════
run_leg2b() {
  info "Leg 2b: Python/Spin native macOS (port 5033)"
  require_port_free 5033 "Leg 2b"

  pushd "$SCRIPT_DIR/python-spin" >/dev/null
    APP_2B=$(human_size app.py)
    BUILD_2B=$(timed_build "spin build (python)" spin build --quiet 2>/dev/null)
    ARTIFACT_2B=$(human_size app.wasm)
    RUNTIME_2B="spin $(spin --version 2>&1 | head -1 | awk '{print $NF}')"

    spin up --listen "127.0.0.1:5033" &>/dev/null &
    SPIN_2B_PID=$!
    PIDS_TO_KILL+=("$SPIN_2B_PID")
    COLD_2B=$(cold_start_ms 5033)
    ok "cold start: ${COLD_2B}ms  app: $APP_2B  artifact: $ARTIFACT_2B  build: ${BUILD_2B}ms"

    HEY_2B=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5033/")
    RSS_2B=$(rss_mb "$SPIN_2B_PID")
    kill_and_wait "$SPIN_2B_PID"
    PIDS_TO_KILL=("${PIDS_TO_KILL[@]/$SPIN_2B_PID}")
    ok "hey done  rss: ${RSS_2B}MB  p50: $(hey_stat "$HEY_2B" p50)ms  p95: $(hey_stat "$HEY_2B" p95)ms  rps: $(hey_stat "$HEY_2B" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 2c: Python → Spin (Spin-in-podman)
# ══════════════════════════════════════════════════════════════════════════════
run_leg2c() {
  info "Leg 2c: Python/Spin podman (port 5034)"
  require_port_free 5034 "Leg 2c"

  pushd "$SCRIPT_DIR" >/dev/null
    [ -f python-spin/app.wasm ] || { pushd python-spin >/dev/null; spin build --quiet 2>/dev/null; popd >/dev/null; }

    $CONTAINER_CMD build -t hello-py-spin \
      --build-arg APP_DIR=python-spin \
      --build-arg WASM_SRC=app.wasm \
      --build-arg WASM_DST=app.wasm \
      -f Containerfile . &>/dev/null
    RUNTIME_2C=$($CONTAINER_CMD image inspect hello-py-spin --format '{{.Size}}' \
      | awk '{printf "%.0fMB", $1/1048576}')

    $CONTAINER_CMD run -d --name bench-py-spin -p 5034:3000 hello-py-spin &>/dev/null
    CONTAINERS_TO_KILL+=("bench-py-spin")

    CTR_2C_PID=$($CONTAINER_CMD inspect --format '{{.State.Pid}}' bench-py-spin 2>/dev/null || echo 0)
    COLD_2C=$(cold_start_ms 5034)
    APP_2C="${APP_2B:-n/a}"
    ARTIFACT_2C="${ARTIFACT_2B:-n/a}"
    ok "cold start: ${COLD_2C}ms  image: $RUNTIME_2C"

    HEY_2C=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5034/")
    RSS_2C=$(rss_mb "$CTR_2C_PID")
    $CONTAINER_CMD rm -f bench-py-spin &>/dev/null
    CONTAINERS_TO_KILL=("${CONTAINERS_TO_KILL[@]/bench-py-spin}")
    ok "hey done  rss: ${RSS_2C}MB  p50: $(hey_stat "$HEY_2C" p50)ms  p95: $(hey_stat "$HEY_2C" p95)ms  rps: $(hey_stat "$HEY_2C" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 3: Rust → cargo wasm32-wasip2 → wasmtime serve (baseline from exp 001)
# ══════════════════════════════════════════════════════════════════════════════
run_leg3() {
  info "Leg 3: Rust baseline wasmtime serve (port 5035)"
  require_port_free 5035 "Leg 3"
  command -v cargo &>/dev/null || fail "cargo not found"

  pushd "$SCRIPT_DIR/rust-hello" >/dev/null
    APP_3=$(human_size src/lib.rs)
    BUILD_3=$(timed_build "cargo wasm32-wasip2" \
      cargo build --target wasm32-wasip2 --release --quiet 2>/dev/null)
    WASM_3=$(find target/wasm32-wasip2/release -maxdepth 1 -name "*.wasm" | head -1)
    ARTIFACT_3=$(human_size "$WASM_3")
    RUNTIME_3="wasmtime $(wasmtime --version | awk '{print $2}')"

    wasmtime serve -S cli --addr "127.0.0.1:5035" "$WASM_3" &>/dev/null &
    WM_3_PID=$!
    PIDS_TO_KILL+=("$WM_3_PID")
    COLD_3=$(cold_start_ms 5035)
    ok "cold start: ${COLD_3}ms  app: $APP_3  artifact: $ARTIFACT_3  build: ${BUILD_3}ms"

    HEY_3=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5035/")
    RSS_3=$(rss_mb "$WM_3_PID")
    kill_and_wait "$WM_3_PID"
    PIDS_TO_KILL=("${PIDS_TO_KILL[@]/$WM_3_PID}")
    ok "hey done  rss: ${RSS_3}MB  p50: $(hey_stat "$HEY_3" p50)ms  p95: $(hey_stat "$HEY_3" p95)ms  rps: $(hey_stat "$HEY_3" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# LEG 4: AssemblyScript → asc + wasm-tools → wasmtime serve (native macOS)
# ══════════════════════════════════════════════════════════════════════════════
run_leg4() {
  info "Leg 4: AssemblyScript/wasmtime serve (port 5036)"
  require_port_free 5036 "Leg 4"

  pushd "$SCRIPT_DIR/as-hello" >/dev/null
    APP_4=$(human_size assembly/index.ts)
    npm ci --silent || npm install --silent
    BUILD_4=$(timed_build "asc + wasm-tools" ./build.sh)
    ARTIFACT_4=$(human_size build/hello-as.wasm)
    RUNTIME_4="wasmtime $(wasmtime --version | awk '{print $2}')"

    wasmtime serve -S cli build/hello-as.wasm --addr "127.0.0.1:5036" &>/dev/null &
    WM_4_PID=$!
    PIDS_TO_KILL+=("$WM_4_PID")
    COLD_4=$(cold_start_ms 5036)
    ok "cold start: ${COLD_4}ms  app: $APP_4  artifact: $ARTIFACT_4  build: ${BUILD_4}ms"

    HEY_4=$(hey -n $HEY_N -c $HEY_C "http://127.0.0.1:5036/")
    RSS_4=$(rss_mb "$WM_4_PID")
    kill_and_wait "$WM_4_PID"
    PIDS_TO_KILL=("${PIDS_TO_KILL[@]/$WM_4_PID}")
    ok "hey done  rss: ${RSS_4}MB  p50: $(hey_stat "$HEY_4" p50)ms  p95: $(hey_stat "$HEY_4" p95)ms  rps: $(hey_stat "$HEY_4" rps)"
  popd >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# Results table
# ══════════════════════════════════════════════════════════════════════════════
print_results() {
  echo ""
  echo "## Results — Experiment 003: JS, Python & AS → .wasm"
  echo ""
  printf "| %-22s | %-20s | %-20s | %-24s | %-20s | %-20s | %-18s | %-18s |\n" \
    "Metric" \
    "1a JS/Spin native" \
    "1b JS/Spin podman" \
    "2a Py/raw wasmtime" \
    "2b Py/Spin native" \
    "2c Py/Spin podman" \
    "3 Rust baseline" \
    "4 AS/wasmtime"
  printf "| %-22s | %-20s | %-20s | %-24s | %-20s | %-20s | %-18s | %-18s |\n" \
    "---" "---" "---" "---" "---" "---" "---" "---"
  printf "| %-22s | %-20s | %-20s | %-24s | %-20s | %-20s | %-18s | %-18s |\n" \
    "Source size"       "${APP_1A:-n/a}"    "${APP_1B:-n/a}"    "${APP_2A:-n/a}"      "${APP_2B:-n/a}"    "${APP_2C:-n/a}"    "${APP_3:-n/a}"    "${APP_4:-n/a}"
  printf "| %-22s | %-20s | %-20s | %-24s | %-20s | %-20s | %-18s | %-18s |\n" \
    "Artifact (.wasm)"  "${ARTIFACT_1A:-n/a}" "${ARTIFACT_1B:-n/a}" "${ARTIFACT_2A:-n/a}" "${ARTIFACT_2B:-n/a}" "${ARTIFACT_2C:-n/a}" "${ARTIFACT_3:-n/a}" "${ARTIFACT_4:-n/a}"
  printf "| %-22s | %-20s | %-20s | %-24s | %-20s | %-20s | %-18s | %-18s |\n" \
    "Build time (ms)"   "${BUILD_1A:-n/a}"  "-"                 "${BUILD_2A:-n/a}"    "${BUILD_2B:-n/a}"  "-"                 "${BUILD_3:-n/a}"  "${BUILD_4:-n/a}"
  printf "| %-22s | %-20s | %-20s | %-24s | %-20s | %-20s | %-18s | %-18s |\n" \
    "Runtime/image"     "${RUNTIME_1A:-n/a}" "${RUNTIME_1B:-n/a}" "${RUNTIME_2A:-n/a}" "${RUNTIME_2B:-n/a}" "${RUNTIME_2C:-n/a}" "${RUNTIME_3:-n/a}" "${RUNTIME_4:-n/a}"
  printf "| %-22s | %-20s | %-20s | %-24s | %-20s | %-20s | %-18s | %-18s |\n" \
    "Cold start (ms)"   "${COLD_1A:-n/a}"   "${COLD_1B:-n/a}"   "${COLD_2A:-n/a}"     "${COLD_2B:-n/a}"   "${COLD_2C:-n/a}"   "${COLD_3:-n/a}"   "${COLD_4:-n/a}"
  printf "| %-22s | %-20s | %-20s | %-24s | %-20s | %-20s | %-18s | %-18s |\n" \
    "Memory RSS (MB)"   "${RSS_1A:-n/a}"    "${RSS_1B:-n/a}"    "${RSS_2A:-n/a}"      "${RSS_2B:-n/a}"    "${RSS_2C:-n/a}"    "${RSS_3:-n/a}"    "${RSS_4:-n/a}"
  printf "| %-22s | %-20s | %-20s | %-24s | %-20s | %-20s | %-18s | %-18s |\n" \
    "hey p50 (ms)"      "$(hey_stat "${HEY_1A:-}" p50)"  "$(hey_stat "${HEY_1B:-}" p50)"  "$(hey_stat "${HEY_2A:-}" p50)"  "$(hey_stat "${HEY_2B:-}" p50)"  "$(hey_stat "${HEY_2C:-}" p50)"  "$(hey_stat "${HEY_3:-}" p50)"  "$(hey_stat "${HEY_4:-}" p50)"
  printf "| %-22s | %-20s | %-20s | %-24s | %-20s | %-20s | %-18s | %-18s |\n" \
    "hey p95 (ms)"      "$(hey_stat "${HEY_1A:-}" p95)"  "$(hey_stat "${HEY_1B:-}" p95)"  "$(hey_stat "${HEY_2A:-}" p95)"  "$(hey_stat "${HEY_2B:-}" p95)"  "$(hey_stat "${HEY_2C:-}" p95)"  "$(hey_stat "${HEY_3:-}" p95)"  "$(hey_stat "${HEY_4:-}" p95)"
  printf "| %-22s | %-20s | %-20s | %-24s | %-20s | %-20s | %-18s | %-18s |\n" \
    "hey req/s"         "$(hey_stat "${HEY_1A:-}" rps)"  "$(hey_stat "${HEY_1B:-}" rps)"  "$(hey_stat "${HEY_2A:-}" rps)"  "$(hey_stat "${HEY_2B:-}" rps)"  "$(hey_stat "${HEY_2C:-}" rps)"  "$(hey_stat "${HEY_3:-}" rps)"  "$(hey_stat "${HEY_4:-}" rps)"
  echo ""

  echo "### Hypothesis outcomes"
  echo ""
  echo "| # | Hypothesis | Leg | Outcome |"
  echo "| - | ---------- | --- | ------- |"
  local py_raw_mb="n/a"; [ -n "${ARTIFACT_2A:-}" ] && py_raw_mb="${ARTIFACT_2A}"
  echo "| H1 | componentize-py .wasm >10MB (CPython embedded) | 2a | artifact: $py_raw_mb |"
  echo "| H2 | Spin abstracts WIT/wasi-http with <5 lines config | 1a, 2b | see spin.toml |"
  local cold_1a="n/a"; [ -n "${COLD_1A:-}" ] && cold_1a="${COLD_1A}ms"
  local cold_2b="n/a"; [ -n "${COLD_2B:-}" ] && cold_2b="${COLD_2B}ms"
  echo "| H3 | Native spin up cold start <100ms | 1a, 2b | 1a: $cold_1a  2b: $cold_2b |"
  local cold_1b="n/a"; [ -n "${COLD_1B:-}" ] && cold_1b="${COLD_1B}ms"
  local cold_2c="n/a"; [ -n "${COLD_2C:-}" ] && cold_2c="${COLD_2C}ms"
  echo "| H4 | Podman overhead <200ms vs native | 1b vs 1a, 2c vs 2b | 1b: $cold_1b  2c: $cold_2c |"
  local art_3="n/a"; [ -n "${ARTIFACT_3:-}" ] && art_3="${ARTIFACT_3}"
  echo "| H5 | Rust .wasm smallest + fastest cold start | 3 | artifact: $art_3  cold: ${COLD_3:-n/a}ms |"
  echo "| H6 | Spin Python uses componentize-py (.wasm same size as 2a) | 2a vs 2b | 2a: $py_raw_mb  2b: ${ARTIFACT_2B:-n/a} |"
  local art_4="n/a"; [ -n "${ARTIFACT_4:-}" ] && art_4="${ARTIFACT_4}"
  echo "| H7 | AssemblyScript .wasm ~10-50KB (no runtime, like Rust) | 4 | artifact: $art_4 |"
  echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════"
echo "  Experiment 003 — JS, Python & AS → .wasm Benchmark"
echo "════════════════════════════════════════════════"
echo ""

run_leg "Leg 1a" run_leg1a
run_leg "Leg 1b" run_leg1b
run_leg "Leg 2a" run_leg2a
run_leg "Leg 2b" run_leg2b
run_leg "Leg 2c" run_leg2c
run_leg "Leg 3"  run_leg3
run_leg "Leg 4"  run_leg4

print_results

if [ ${#FAILED_LEGS[@]} -gt 0 ]; then
  echo -e "${RED}Failed legs: ${FAILED_LEGS[*]}${NC}"
  exit 1
fi
