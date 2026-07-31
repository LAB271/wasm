// tests/wasm.test.mjs — loads both compiled engines directly (no browser,
// no server) and checks: each one scores correctly, and they agree with
// each other on every case. Run after `make build`.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));

async function loadEngine(name) {
  const bytes = await readFile(`${root}web/engine-${name}.wasm`);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  return instance.exports.score_guess;
}

function unpack(packed) {
  return { blacks: Math.floor(packed / 16), whites: packed % 16 };
}

const CASES = [
  { secret: [0, 1, 2, 3], guess: [0, 1, 2, 3], expect: { blacks: 4, whites: 0 } },
  { secret: [0, 1, 2, 3], guess: [3, 2, 1, 0], expect: { blacks: 0, whites: 4 } },
  { secret: [0, 0, 1, 2], guess: [0, 1, 1, 3], expect: { blacks: 2, whites: 0 } },
  { secret: [0, 0, 1, 2], guess: [0, 0, 0, 0], expect: { blacks: 2, whites: 0 } },
  { secret: [0, 0, 0, 0], guess: [1, 1, 1, 1], expect: { blacks: 0, whites: 0 } },
  { secret: [5, 4, 3, 2], guess: [2, 3, 4, 5], expect: { blacks: 0, whites: 4 } },
];

let failures = 0;

for (const name of ["rust", "as"]) {
  const score_guess = await loadEngine(name);
  for (const { secret, guess, expect } of CASES) {
    const got = unpack(score_guess(...secret, ...guess));
    try {
      assert.deepEqual(got, expect);
      console.log(`ok  [${name}] secret=${secret} guess=${guess} -> ${JSON.stringify(got)}`);
    } catch {
      failures++;
      console.error(`FAIL [${name}] secret=${secret} guess=${guess} -> got ${JSON.stringify(got)}, want ${JSON.stringify(expect)}`);
    }
  }
}

// Cross-check: both engines must agree on a wider sweep, not just the
// hand-picked cases above.
const rust = await loadEngine("rust");
const as = await loadEngine("as");
for (let i = 0; i < 200; i++) {
  const rand4 = () => Array.from({ length: 4 }, () => Math.floor(Math.random() * 6));
  const secret = rand4();
  const guess = rand4();
  const a = rust(...secret, ...guess);
  const b = as(...secret, ...guess);
  if (a !== b) {
    failures++;
    console.error(`FAIL [parity] secret=${secret} guess=${guess} -> rust=${a} as=${b}`);
  }
}

if (failures > 0) {
  console.error(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("\nall wasm tests passed");
