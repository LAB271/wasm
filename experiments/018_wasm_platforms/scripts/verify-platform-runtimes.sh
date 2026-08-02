#!/bin/bash
# Installs (if missing) and version-checks the local, open-source runtime for
# each of the four platforms surveyed in this experiment. This only confirms
# "installable + runnable on this arm64 Mac" — see portability-test.sh for the
# actual hello-world/portability runs.
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
check() {
    local name="$1"; shift
    if "$@" &>/tmp/wasm018-check.log; then
        echo "  OK   $name: $(head -1 /tmp/wasm018-check.log)"
        pass=$((pass+1))
    else
        echo "  FAIL $name (see /tmp/wasm018-check.log)"
        fail=$((fail+1))
    fi
}

echo "=== Four-platform local runtime survey ==="
echo ""

echo "-- Fermyon Cloud -> Spin (already installed per machine facts) --"
check "spin" spin --version

echo ""
echo "-- wasmCloud -> wash (Wasm Shell) --"
if ! command -v wash &>/dev/null; then
    echo "  installing: brew install wasmcloud/wasmcloud/wash"
    brew install wasmcloud/wasmcloud/wash
fi
check "wash" wash --version

echo ""
echo "-- Cloudflare Workers -> workerd via wrangler dev --"
NPM_BIN="$(npm config get prefix 2>/dev/null)/bin"
export PATH="$PATH:${NPM_BIN}"
if ! command -v wrangler &>/dev/null; then
    echo "  installing: npm install -g --allow-scripts=esbuild,workerd wrangler"
    echo "  (--allow-scripts is required: workerd's postinstall downloads the"
    echo "   actual workerd binary; npm's default sandboxing blocks it)"
    npm install -g --allow-scripts=esbuild,workerd wrangler
fi
check "wrangler" wrangler --version

echo ""
echo "-- Fastly Compute -> Viceroy via the fastly CLI --"
if ! command -v fastly &>/dev/null; then
    echo "  installing: brew install fastly"
    brew install fastly
fi
check "fastly" fastly version
echo "  note: 'fastly compute serve' downloads the actual Viceroy binary itself"
echo "  on first use (not brew/cargo) — see portability-test.sh."

echo ""
echo "=== $pass installed+runnable, $fail failed ==="
[ "$fail" -eq 0 ]
