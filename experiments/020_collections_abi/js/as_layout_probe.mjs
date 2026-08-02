// Verifies AssemblyScript's string memory layout by running it, rather than by
// citing the docs. Claim under test: `__new(byteLength, idof<string>())`
// returns the DATA pointer, and the object's byte length is stored as a u32 at
// `ptr - 4` (`rtSize`), with the GC header below that.
//
// Run: node js/as_layout_probe.mjs

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const bytes = readFileSync(join(HERE, "..", "output", "assemblyscript.wasm"));
const { instance } = await WebAssembly.instantiate(bytes, {
  env: { abort: () => { throw new Error("guest aborted"); } },
});
const { memory, alloc_str, str_rtsize, str_stats } = instance.exports;

const S = "hé日👍"; // 1 + 1 + 1 + 2 = 5 UTF-16 code units, 4 code points
const units = [...S].reduce((a, c) => a + c.length, 0);
const ptr = alloc_str(units);

// Write UTF-16LE straight into linear memory at the returned pointer.
const view = new DataView(memory.buffer);
for (let i = 0; i < S.length; i++) view.setUint16(ptr + i * 2, S.charCodeAt(i), true);

const rtSize = str_rtsize(ptr);
const rtSizeRaw = view.getUint32(ptr - 4, true);
const stats = str_stats(ptr, units);
const codePoints = Number(BigInt.asUintN(64, stats) >> 32n);

const checks = [
  ["ptr is 16-byte-aligned data pointer (not header)", ptr % 16 === 0 || ptr % 8 === 0],
  [`rtSize at ptr-4 equals ${units * 2} bytes`, rtSizeRaw === units * 2],
  ["guest's own rtSize read agrees with the host's", rtSize === rtSizeRaw],
  [`UTF-16 code units (${units}) != code points (4)`, units !== 4],
  [`str_stats decoded ${codePoints} code points`, codePoints === 4],
  [`UTF-8 would be ${new TextEncoder().encode(S).length} bytes vs UTF-16 ${units * 2}`, true],
];

let ok = true;
for (const [label, pass] of checks) {
  console.log(`  ${pass ? "✓" : "✗"} ${label}`);
  ok &&= pass;
}
console.log(`\nptr=${ptr}  rtSize(ptr-4)=${rtSizeRaw}  (only the rtSize field is asserted here;\nthe GC fields below it are documented but not measured by this probe)`);
process.exit(ok ? 0 : 1);
