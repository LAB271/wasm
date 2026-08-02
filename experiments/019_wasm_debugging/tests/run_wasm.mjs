// Node-side counterpart to host/src/main.rs — same job, JS host instead of
// a native Rust host. Satisfies the `env.host_log` import (this is exactly
// what a browser page would do with `console.log`) and calls one exported
// function, printing the return value or the trap's stack (V8's
// WebAssembly.RuntimeError#stack) on failure.
//
// Usage: node run_wasm.mjs <path-to.wasm> <export-fn> <u32-arg>
import { readFile } from "node:fs/promises";

const [, , wasmPath, funcName, argStr] = process.argv;
if (!wasmPath || !funcName || argStr === undefined) {
  console.error("usage: node run_wasm.mjs <path-to.wasm> <export-fn> <u32-arg>");
  process.exit(2);
}
const arg = Number(argStr);

const bytes = await readFile(wasmPath);
const imports = {
  env: {
    host_log(ptr, len) {
      const mem = new Uint8Array(instance.exports.memory.buffer, ptr, len);
      const msg = Buffer.from(mem).toString("utf8");
      console.log(`[host_log via Node/V8 host] ${msg}`);
    },
  },
};

const { instance } = await WebAssembly.instantiate(bytes, imports);
const fn = instance.exports[funcName];
if (typeof fn !== "function") {
  console.error(`no export named "${funcName}" (available: ${Object.keys(instance.exports).join(", ")})`);
  process.exit(2);
}

try {
  // i64 returns come back as BigInt under the JS API.
  const result = fn(arg);
  console.log(`${funcName}(${arg}) = ${result}`);
} catch (err) {
  console.log(`TRAP calling ${funcName}(${arg}):`);
  console.log(err.stack ?? String(err));
}
