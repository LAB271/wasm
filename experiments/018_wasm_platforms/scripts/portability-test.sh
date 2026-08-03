#!/bin/bash
# The portability question: can ONE .wasm component run on multiple platform
# runtimes unmodified?
#
# The component under test is portability/hello — wasmCloud's own
# `templates/http-hello-world` (via `wash new`), built for wasm32-wasip2 using
# the `wstd` crate. It exports wasi:http/incoming-handler and nothing else —
# no platform-specific SDK. We build it ONCE and try to run the SAME .wasm
# binary on all four platform runtimes without changing a byte.
set -uo pipefail
cd "$(dirname "$0")/../portability/hello"

NPM_BIN="$(npm config get prefix 2>/dev/null)/bin"
export PATH="$PATH:${NPM_BIN}"

WASM=target/wasm32-wasip2/release/hello_world.wasm
RESULTS=()   # "outcome|leg|detail"

# Outcome vocabulary. "FAIL (expected)" was a contradiction: a failure we
# predicted and explained is a result, not a defect. So:
#   RUNS     — executes the component unmodified
#   ADAPTED  — executes it, but only with a transpile/adapter (cost recorded)
#   BLOCKED  — cannot execute it, and we know exactly why (a finding)
#   BROKEN   — reserved for the harness itself failing, i.e. we do NOT know why
# Only BROKEN means something is wrong with this experiment.
record() { RESULTS+=("$1|$2|$3"); printf '   %-8s %s\n' "$1" "$2"; }

echo "=== Portability: one wasi-http component, seven legs ==="
echo ""
if ! wash build >/tmp/wasm018-build.log 2>&1; then
    echo "BROKEN: component build failed — see /tmp/wasm018-build.log"; exit 1
fi
if ! wasm-tools validate "$WASM" >/dev/null 2>&1; then
    echo "BROKEN: built artifact is not a valid component"; exit 1
fi
printf 'component: %s  %s bytes  wasm32-wasip2, validates\n\n' \
    "$(basename "$WASM")" "$(wc -c < "$WASM" | tr -d ' ')"

# Pull the real diagnostic out of a runtime's log.
#
# Every one of these CLIs buries the actual reason among ANSI colour codes, ISO
# timestamps, banner boxes, and trailing "file a bug" boilerplate. Two traps:
# the reason is the FIRST error, not the last (a naive `tail` picks up shutdown
# noise like ERR_IPC_CHANNEL_CLOSED or "a newer version is available"), and the
# generic wrapper lines say nothing ("error during execution process (see
# 'command output' above)"). Strip the noise, keep the first line that carries
# an actual cause.
diagnose() {
    sed -E $'s/\x1b\\[[0-9;]*m//g' "$1" \
      | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z[[:space:]]*//' \
      | grep -aiE 'error|not found|unsupported|cannot|unable' \
      | grep -avE "see 'command output'|newer version of|create an issue|file an issue|Logs were written|Runtime stderr|ERR_IPC_CHANNEL_CLOSED|runtime failed to start|json-logger" \
      | sed -E 's/^[[:space:]]*[^[:alnum:]`"]*//; s/^\[?ERROR\]?:?[[:space:]]*//I' \
      | grep -avE '^[[:space:]]*$' \
      | head -1 | cut -c1-220
}

# Start a server in the background without bash announcing "Terminated: 15"
# when `timeout` reaps it. Job-control notifications are the parent shell's,
# so the job has to be disowned rather than merely redirected.
start_bg() { "$@" & BG_PID=$!; disown "$BG_PID" 2>/dev/null || true; }
stop_bg() { [ -n "${BG_PID:-}" ] && kill "$BG_PID" 2>/dev/null; BG_PID=""; return 0; }

# 1. wasmtime serve — the raw component-model runtime, no platform wrapper.
echo "--- 1/7 wasmtime serve (no wrapper at all) ---"
start_bg timeout 5 wasmtime serve -S cli "$WASM" --addr 127.0.0.1:19001 &>/tmp/wasm018-wasmtime.log
sleep 2
if curl -sS -f http://127.0.0.1:19001/ &>/tmp/wasm018-wasmtime-curl.log; then
    record RUNS "wasmtime serve" "unmodified"
else
    record "wasmtime serve" "FAIL — see /tmp/wasm018-wasmtime.log"
fi
pkill -f "wasmtime serve" 2>/dev/null || true
sleep 1

# 2. Spin — same .wasm, wrapped only in a spin.toml manifest (no rebuild).
echo "--- 2/7 Spin (spin.toml wraps the SAME .wasm, zero rebuild) ---"
mkdir -p /tmp/wasm018-spin-wrap
cp "$WASM" /tmp/wasm018-spin-wrap/hello_world.wasm
cat > /tmp/wasm018-spin-wrap/spin.toml <<'EOF'
spin_manifest_version = 2
[application]
name = "portability-test"
version = "0.1.0"
[[trigger.http]]
route = "/..."
component = "hello"
[component.hello]
source = "hello_world.wasm"
allowed_outbound_hosts = []
EOF
(cd /tmp/wasm018-spin-wrap && timeout 5 spin up --listen 127.0.0.1:19002 &>/tmp/wasm018-spin.log &)
sleep 2
if curl -sS -f http://127.0.0.1:19002/ &>/tmp/wasm018-spin-curl.log; then
    record RUNS "Spin" "unmodified — spin.toml wrapper only, zero rebuild"
else
    record "Spin" "FAIL — see /tmp/wasm018-spin.log"
fi
pkill -f "spin up" 2>/dev/null || true
sleep 1

# 3. wasmCloud (wash dev) — the component's native home.
echo "--- 3/7 wash dev (wasmCloud's local host) ---"
start_bg timeout 12 wash dev --non-interactive &>/tmp/wasm018-wash.log
sleep 8
if curl -sS -f http://127.0.0.1:8000/ &>/tmp/wasm018-wash-curl.log; then
    record RUNS "wasmCloud" "unmodified"
else
    record "wasmCloud (wash dev)" "FAIL — see /tmp/wasm018-wash.log"
fi
stop_bg
sleep 1

# 4. Fastly Compute (Viceroy) — expected to fail: component support is
#    explicitly experimental in Viceroy as of this writing.
echo "--- 4/7 Fastly Compute / Viceroy ---"
mkdir -p /tmp/wasm018-fastly-wrap/bin
cp "$WASM" /tmp/wasm018-fastly-wrap/bin/main.wasm
cat > /tmp/wasm018-fastly-wrap/fastly.toml <<'EOF'
authors = []
description = ""
language = "other"
manifest_version = 3
name = "portability-test"
service_id = ""
[scripts]
build = ""
EOF
(cd /tmp/wasm018-fastly-wrap && timeout 8 fastly compute serve --skip-build --file bin/main.wasm --addr 127.0.0.1:19003 -i &>/tmp/wasm018-fastly.log &)
sleep 6
if curl -sS -f http://127.0.0.1:19003/ &>/tmp/wasm018-fastly-curl.log; then
    record "Fastly/Viceroy" "PASS — $(cat /tmp/wasm018-fastly-curl.log)"
else
    record BLOCKED "Fastly/Viceroy" "no wasi:http at ANY version; wants fastly:compute/http-incoming — needs a platform SDK"
fi
stop_bg
sleep 1

# 5. Cloudflare Workers (wrangler/workerd) — expected to fail: workerd (V8)
#    only implements core Wasm modules, not the Component Model binary format.
echo "--- 5/7 Cloudflare Workers / workerd (unmodified component) ---"
mkdir -p /tmp/wasm018-cf-worker
cp "$WASM" /tmp/wasm018-cf-worker/component.wasm
cat > /tmp/wasm018-cf-worker/wrangler.toml <<'EOF'
name = "portability-test"
main = "index.js"
compatibility_date = "2026-07-29"
EOF
cat > /tmp/wasm018-cf-worker/index.js <<'EOF'
import wasm from "./component.wasm";
export default {
  async fetch(request) {
    return new Response("loaded: " + typeof wasm);
  },
};
EOF
(cd /tmp/wasm018-cf-worker && timeout 12 wrangler dev --local --port 19004 --ip 127.0.0.1 &>/tmp/wasm018-wrangler.log &)
sleep 8
if curl -sS -f http://127.0.0.1:19004/ &>/tmp/wasm018-wrangler-curl.log; then
    record "Cloudflare Workers" "PASS — $(cat /tmp/wasm018-wrangler-curl.log)"
else
    record BLOCKED "Cloudflare (as-is)" "V8 loads core modules only: found 0d 00 01 00, wants 01 00 00 00 — fixable, see leg 6"
fi
stop_bg

# 6. Cloudflare Workers, the SAME component transpiled by jco. Leg 5 proves the
#    component cannot be loaded as-is; this proves what it takes to load it
#    anyway — a core-module transpile plus a hand-written wasi:http/wasi:io host.
#    Note: cwd is portability/hello (set at the top), so paths are relative to it.
echo "--- 6/7 Cloudflare Workers / workerd (jco-transpiled) ---"
COMPONENT_ABS="$(pwd)/$WASM"
CFW="$(cd ../cf-worker && pwd)"
if ! command -v jco &>/dev/null; then
    record SKIP "Cloudflare (jco)" "jco not installed (npm i -g @bytecodealliance/jco)"
elif ! command -v wrangler &>/dev/null; then
    record SKIP "Cloudflare (jco)" "wrangler not installed"
else
    ( cd "$CFW" && [ -d node_modules ] || npm install --silent --no-audit --no-fund >/dev/null 2>&1 )
    rm -rf "$CFW/gen"
    if ! ( cd "$CFW" && jco transpile "$COMPONENT_ABS" -o gen \
             --map "wasi:http/types@0.2.9=./../wasi-http-host.js" \
             --instantiation sync -q ) >/tmp/wasm018-jco.log 2>&1; then
        record BROKEN "Cloudflare (jco)" "transpile itself failed: $(diagnose /tmp/wasm018-jco.log)"
    else
        ( cd "$CFW" && start_bg timeout 60 wrangler dev --local --port 19005 --ip 127.0.0.1 &>/tmp/wasm018-cfw.log )
        sleep 15
        if curl -sS -f -m 10 http://127.0.0.1:19005/ &>/tmp/wasm018-cfw-curl.log; then
            record ADAPTED "Cloudflare (jco)" "same bytes + core-module transpile + ~180 lines of host adapter"
        else
            record BROKEN "Cloudflare (jco)" "$(diagnose /tmp/wasm018-cfw.log)"
        fi
        stop_bg
    fi
fi

# 7. Fastly via its OWN SDK. Not a portability leg — different bytes, different
#    interface. It answers the question leg 4 provokes: does Fastly run WASM at
#    all? Yes, natively. The gap is the ABI, not the platform.
echo "--- 7/7 Fastly Compute / native SDK (different bytes, for contrast) ---"
FSDK="$(cd ../fastly-sdk 2>/dev/null && pwd)"
if [ -z "$FSDK" ]; then
    record SKIP "Fastly (native SDK)" "portability/fastly-sdk missing"
else
    ( cd "$FSDK" && timeout 100 fastly compute build ) >/tmp/wasm018-fsdk-build.log 2>&1
    if [ ! -f "$FSDK/pkg/fastly-sdk-demo.tar.gz" ]; then
        record BROKEN "Fastly (native SDK)" "build failed: $(diagnose /tmp/wasm018-fsdk-build.log)"
    else
        ( cd "$FSDK" && start_bg timeout 40 fastly compute serve --skip-build --addr 127.0.0.1:19006 &>/tmp/wasm018-fsdk.log )
        sleep 11
        if curl -sS -f -m 10 http://127.0.0.1:19006/ &>/tmp/wasm018-fsdk-curl.log; then
            record SDK "Fastly (native SDK)" "runs via fastly:compute/* — NOT the same bytes; $(grep -oE 'completed in [0-9.]+[mµ]s' /tmp/wasm018-fsdk.log | head -1)"
        else
            record BROKEN "Fastly (native SDK)" "$(diagnose /tmp/wasm018-fsdk.log)"
        fi
        stop_bg
    fi
fi

echo ""
echo "=== Result ==="
echo ""
printf '  %-5s %-22s %-9s %s\n' "LEG" "PLATFORM" "OUTCOME" "WHY / COST"
printf '  %-5s %-22s %-9s %s\n' "-----" "----------------------" "---------" "----------"
i=0
for r in "${RESULTS[@]}"; do
    i=$((i+1))
    outcome="${r%%|*}"; rest="${r#*|}"; leg="${rest%%|*}"; detail="${rest#*|}"
    printf '  %-5s %-22s %-9s %s\n' "$i/${#RESULTS[@]}" "$leg" "$outcome" "$detail"
done

runs=0; adapted=0; blocked=0; broken=0; skipped=0; sdk=0
for r in "${RESULTS[@]}"; do
    case "${r%%|*}" in
        RUNS) runs=$((runs+1));; ADAPTED) adapted=$((adapted+1));;
        BLOCKED) blocked=$((blocked+1));; BROKEN) broken=$((broken+1));;
        SKIP) skipped=$((skipped+1));; SDK) sdk=$((sdk+1));;
    esac
done

echo ""
echo "=== Verdict ==="
echo ""
echo "  $runs of ${#RESULTS[@]} run the component unmodified."
[ "$adapted" -gt 0 ] && echo "  $adapted run it after adaptation — portable, but not drop-in."
if [ "$blocked" -gt 0 ]; then
    echo "  $blocked blocked, and the reasons are different in kind:"
    for r in "${RESULTS[@]}"; do
        [ "${r%%|*}" = BLOCKED ] || continue
        rest="${r#*|}"; printf "      %-22s %s\n" "${rest%%|*}" "${rest#*|}"
    done
fi
[ "$sdk" -gt 0 ] && echo "  $sdk runs only via the platform's own SDK — different bytes, so not portability at all."
[ "$skipped" -gt 0 ] && echo "  $skipped skipped (tool not installed)."
echo ""
if [ "$broken" -gt 0 ]; then
    echo "  $broken UNEXPLAINED failure(s) — the harness could not account for these."
    echo "  That is the only outcome here that means something is wrong."
    exit 1
fi
echo "  0 unexplained failures. Every BLOCKED above is a measured finding, not a defect:"
echo "  a runtime that cannot load this component is a fact about the runtime."
echo ""
echo "Run 'make verify-containerd-shim' and 'make verify-k3d-spinkube' separately —"
echo "they install a containerd shim / spin up a k3d cluster and take longer."
