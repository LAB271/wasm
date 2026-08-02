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
RESULTS=()

echo "=== Portability test: one wasi-http component, five runtimes ==="
echo ""
echo "-- building (wash build -> cargo build --target wasm32-wasip2 --release) --"
wash build
ls -la "$WASM"
wasm-tools validate "$WASM" && echo "valid component"
echo ""

record() { RESULTS+=("$1: $2"); echo ""; echo ">>> $1: $2"; echo ""; }

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

# 1. wasmtime serve — the raw component-model runtime, no platform wrapper.
echo "--- 1/5 wasmtime serve (no wrapper at all) ---"
(timeout 5 wasmtime serve -S cli "$WASM" --addr 127.0.0.1:19001 &>/tmp/wasm018-wasmtime.log &)
sleep 2
if curl -sS -f http://127.0.0.1:19001/ &>/tmp/wasm018-wasmtime-curl.log; then
    record "wasmtime serve" "PASS — $(cat /tmp/wasm018-wasmtime-curl.log)"
else
    record "wasmtime serve" "FAIL — see /tmp/wasm018-wasmtime.log"
fi
pkill -f "wasmtime serve" 2>/dev/null || true
sleep 1

# 2. Spin — same .wasm, wrapped only in a spin.toml manifest (no rebuild).
echo "--- 2/5 Spin (spin.toml wraps the SAME .wasm, zero rebuild) ---"
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
    record "Spin" "PASS — $(cat /tmp/wasm018-spin-curl.log)"
else
    record "Spin" "FAIL — see /tmp/wasm018-spin.log"
fi
pkill -f "spin up" 2>/dev/null || true
sleep 1

# 3. wasmCloud (wash dev) — the component's native home.
echo "--- 3/5 wash dev (wasmCloud's local host) ---"
(timeout 12 wash dev --non-interactive &>/tmp/wasm018-wash.log &)
sleep 8
if curl -sS -f http://127.0.0.1:8000/ &>/tmp/wasm018-wash-curl.log; then
    record "wasmCloud (wash dev)" "PASS — $(cat /tmp/wasm018-wash-curl.log)"
else
    record "wasmCloud (wash dev)" "FAIL — see /tmp/wasm018-wash.log"
fi
pkill -f "wash dev" 2>/dev/null || true
sleep 1

# 4. Fastly Compute (Viceroy) — expected to fail: component support is
#    explicitly experimental in Viceroy as of this writing.
echo "--- 4/5 Fastly Compute / Viceroy ---"
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
    record "Fastly/Viceroy" "FAIL (expected) — $(diagnose /tmp/wasm018-fastly.log)"
fi
pkill -f "fastly compute serve" 2>/dev/null || true
sleep 1

# 5. Cloudflare Workers (wrangler/workerd) — expected to fail: workerd (V8)
#    only implements core Wasm modules, not the Component Model binary format.
echo "--- 5/5 Cloudflare Workers / workerd ---"
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
    record "Cloudflare Workers" "FAIL (expected) — $(diagnose /tmp/wasm018-wrangler.log)"
fi
pkill -f "wrangler dev" 2>/dev/null || true

echo ""
echo "=== Summary ==="
for r in "${RESULTS[@]}"; do echo "  $r"; done
