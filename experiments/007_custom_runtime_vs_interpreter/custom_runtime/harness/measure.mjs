// measure.mjs — cold start (instantiate + one call) for the custom-runtime leg.
// No browser needed: nothing here is WASI or DOM-dependent, a plain Node
// process instantiating the module is a fair "cold start" measurement,
// analogous in spirit to the other legs' process-launch-to-first-response.
import { readFileSync } from "node:fs";
import { createRuntime } from "./runtime.js";

const bytes = readFileSync(new URL("../rust/target/wasm32-unknown-unknown/release/custom_runtime_demo.wasm", import.meta.url));

const t0 = performance.now();
let memory;
const runtime = createRuntime(() => memory);
const { instance } = await WebAssembly.instantiate(bytes, { runtime: runtime.imports });
memory = instance.exports.memory;

const name = "World";
const nameBytes = new TextEncoder().encode(name);
const inputPtr = instance.exports.input_ptr();
new Uint8Array(memory.buffer, inputPtr, nameBytes.length).set(nameBytes);

const outLen = instance.exports.greet(nameBytes.length);
const outputPtr = instance.exports.output_ptr();
const result = new TextDecoder().decode(new Uint8Array(memory.buffer, outputPtr, outLen));
const coldStartMs = performance.now() - t0;

if (result !== "Hello, World") {
  console.error(JSON.stringify({ ok: false, result }));
  process.exit(1);
}

console.log(JSON.stringify({
  ok: true,
  result,
  coldStartMs,
  handleCount: runtime.handleCount(),
}));
