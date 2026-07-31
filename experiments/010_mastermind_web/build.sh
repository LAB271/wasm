#!/usr/bin/env bash
# build.sh — compile vendor/code.mvl to WASM, patch a confirmed compiler bug,
# and compile the TypeScript UI shell.
#
# Two separate, real WASM-backend bugs are worked around here (not silently
# — both are documented in README.md and were verified by reading the
# compiler's actual WAT output, not assumed):
#
# 1. Dead-code elimination drops string-literal DATA SEGMENTS for `pub`
#    functions never called from `main()`. code.mvl is deliberately a
#    main()-less pure-logic library (that's the whole point of vendoring
#    it — zero effects, zero extern). `mvl build --backend=wasm` still
#    exports color_name correctly and still emits `i32.const <offset>`
#    instructions pointing at where its string bytes SHOULD be, but drops
#    the `(data ...)` segments that would actually put the bytes there.
#    Confirmed by adding a throwaway `fn main() { println(color_name(1)) }`
#    to a scratch copy: the missing segments reappear. Patched here instead
#    of carrying a fork of code.mvl with a fake main() (which would also
#    pull in a wasi_snapshot_preview1 import this browser module has no use
#    for) — see patch-data-segments.mjs.
# 2. render_feedback (Feedback -> String via Int.to_string()) doesn't
#    assemble at all (`unknown func: $mvl_int_to_string`) — excluded from
#    vendor/code.mvl entirely; the UI renders blacks/whites as pegs itself.
#
# Also not usable, unrelated bugs, not worked around (unreachable traps,
# not data-loss — calling them would just crash cleanly): parse_guess,
# render_code. The UI never calls either — see README.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "→ mvl build --backend=wasm"
(cd vendor && mvl build code.mvl --backend=wasm)

echo "→ patching dropped string-literal data segments (see comment above)"
node scripts/patch-data-segments.mjs vendor/code.wat

echo "→ WAT -> WASM binary"
wasm-tools parse vendor/code.wat -o web/code.wasm

echo "→ compiling TypeScript UI"
if [ ! -d web/node_modules ]; then
  echo "  (first run — installing web/ deps)"
  (cd web && npm install --no-audit --no-fund >/dev/null)
fi
(cd web && npx tsc app.ts --target es2020 --module es2020 --lib es2020,dom --strict --outDir dist)

# app.js (in dist/) imports "./mvl-runtime.js" as an ES module — that
# resolves relative to dist/, not web/, so the runtime has to live next to
# the compiled output too.
cp web/mvl-runtime.js web/dist/mvl-runtime.js

echo "done. Serve with: python3 serve.py"
