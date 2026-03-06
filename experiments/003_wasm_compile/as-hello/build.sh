#!/usr/bin/env bash
# Build AssemblyScript → WASI HTTP component
#
# Pipeline:
#   1. asc (AssemblyScript compiler) → core wasm module
#   2. wasm-tools: rename export to canonical ABI name
#   3. wasm-tools component embed: attach WIT metadata
#   4. wasm-tools component new: wrap as WASI HTTP component
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WIT="$SCRIPT_DIR/../python-raw/wit"
BUILD="$SCRIPT_DIR/build"

mkdir -p "$BUILD"

# Step 1: Compile AssemblyScript to core wasm (must run from as-hello dir)
pushd "$SCRIPT_DIR" >/dev/null
npx asc assembly/index.ts \
  --outFile build/hello-as-core.wasm \
  --optimize --exportRuntime --lowMemoryLimit \
  --use abort=assembly/index/abort
popd >/dev/null

# Step 2: Rename 'handle' export to canonical ABI name
wasm-tools print "$BUILD/hello-as-core.wasm" \
  | sed 's/(export "handle"/(export "wasi:http\/incoming-handler@0.2.9#handle"/g' \
  > "$BUILD/hello-as-renamed.wat"
wasm-tools parse "$BUILD/hello-as-renamed.wat" -o "$BUILD/hello-as-renamed.wasm"

# Step 3: Embed WIT metadata for proxy world
wasm-tools component embed "$WIT" --world proxy \
  "$BUILD/hello-as-renamed.wasm" -o "$BUILD/hello-as-embed.wasm"

# Step 4: Create WASI HTTP component
wasm-tools component new "$BUILD/hello-as-embed.wasm" -o "$BUILD/hello-as.wasm"

# Clean intermediates
rm -f "$BUILD/hello-as-core.wasm" "$BUILD/hello-as-renamed.wat" \
      "$BUILD/hello-as-renamed.wasm" "$BUILD/hello-as-embed.wasm"
