// Rematches experiment 010's headline number: "WASM score_guess beats tuned
// JS 1.68x over 1.68M calls." That number used ONE JS formulation
// (switch-chain scalar counters). Here we try 4, pick the best, and report
// honestly whether it closes the gap.
//
// Run under `node --trace-opt --trace-deopt` (see Makefile `rematch` target)
// so the tier-up/deopt check has something to grep.
import { loadWasm, timeRounds, fmtRow } from "./common.mjs";

const OZ = "output/crossover_oz.wasm";
const O3 = "output/crossover_o3.wasm";

// All 1296 four-peg / six-color codes.
const codes = [];
for (let a = 0; a < 6; a++)
  for (let b = 0; b < 6; b++)
    for (let c = 0; c < 6; c++) for (let d = 0; d < 6; d++) codes.push([a, b, c, d]);

// ─── JS formulations ────────────────────────────────────────────────────────

// (1) naive: 4 array allocations per call — what a first-draft implementation
// looks like, and 010's worst-case JS row (59ms/1.68M).
function jsNaive(s0, s1, s2, s3, g0, g1, g2, g3) {
  let blacks = 0;
  const sc = [0, 0, 0, 0, 0, 0];
  const gc = [0, 0, 0, 0, 0, 0];
  const s = [s0, s1, s2, s3];
  const g = [g0, g1, g2, g3];
  for (let i = 0; i < 4; i++) {
    if (s[i] === g[i]) blacks++;
    else {
      sc[s[i]]++;
      gc[g[i]]++;
    }
  }
  let whites = 0;
  for (let i = 0; i < 6; i++) whites += sc[i] < gc[i] ? sc[i] : gc[i];
  return blacks * 16 + whites;
}

// (2) tuned switch: zero allocation, scalar counters, switch chain — 010's
// "allocation-free" row (40ms/1.68M, the 1.68x figure).
function jsTunedSwitch(s0, s1, s2, s3, g0, g1, g2, g3) {
  let b = 0,
    a0 = 0, a1 = 0, a2 = 0, a3 = 0, a4 = 0, a5 = 0,
    b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0;
  if (s0 === g0) b++;
  else {
    switch (s0) { case 0: a0++; break; case 1: a1++; break; case 2: a2++; break; case 3: a3++; break; case 4: a4++; break; default: a5++; }
    switch (g0) { case 0: b0++; break; case 1: b1++; break; case 2: b2++; break; case 3: b3++; break; case 4: b4++; break; default: b5++; }
  }
  if (s1 === g1) b++;
  else {
    switch (s1) { case 0: a0++; break; case 1: a1++; break; case 2: a2++; break; case 3: a3++; break; case 4: a4++; break; default: a5++; }
    switch (g1) { case 0: b0++; break; case 1: b1++; break; case 2: b2++; break; case 3: b3++; break; case 4: b4++; break; default: b5++; }
  }
  if (s2 === g2) b++;
  else {
    switch (s2) { case 0: a0++; break; case 1: a1++; break; case 2: a2++; break; case 3: a3++; break; case 4: a4++; break; default: a5++; }
    switch (g2) { case 0: b0++; break; case 1: b1++; break; case 2: b2++; break; case 3: b3++; break; case 4: b4++; break; default: b5++; }
  }
  if (s3 === g3) b++;
  else {
    switch (s3) { case 0: a0++; break; case 1: a1++; break; case 2: a2++; break; case 3: a3++; break; case 4: a4++; break; default: a5++; }
    switch (g3) { case 0: b0++; break; case 1: b1++; break; case 2: b2++; break; case 3: b3++; break; case 4: b4++; break; default: b5++; }
  }
  const w = (a0 < b0 ? a0 : b0) + (a1 < b1 ? a1 : b1) + (a2 < b2 ? a2 : b2) + (a3 < b3 ? a3 : b3) + (a4 < b4 ? a4 : b4) + (a5 < b5 ? a5 : b5);
  return b * 16 + w;
}

// (3) bit-packed: pack 6 counters into one i32 (4 bits each) via shifts,
// eliminating the switch chain entirely. Only a 6-iteration loop remains,
// to extract+min the nibbles.
function jsBitpacked(s0, s1, s2, s3, g0, g1, g2, g3) {
  let blacks = 0,
    sBits = 0,
    gBits = 0;
  if (s0 === g0) blacks++; else { sBits += 1 << (s0 * 4); gBits += 1 << (g0 * 4); }
  if (s1 === g1) blacks++; else { sBits += 1 << (s1 * 4); gBits += 1 << (g1 * 4); }
  if (s2 === g2) blacks++; else { sBits += 1 << (s2 * 4); gBits += 1 << (g2 * 4); }
  if (s3 === g3) blacks++; else { sBits += 1 << (s3 * 4); gBits += 1 << (g3 * 4); }
  let whites = 0;
  for (let c = 0; c < 6; c++) {
    const sc = (sBits >>> (c * 4)) & 0xf;
    const gc = (gBits >>> (c * 4)) & 0xf;
    whites += sc < gc ? sc : gc;
  }
  return blacks * 16 + whites;
}

// (4) preallocated Int32Array(12) scratch buffer instead of local arrays.
const scratch = new Int32Array(12);
function jsTypedScratch(s0, s1, s2, s3, g0, g1, g2, g3) {
  scratch.fill(0);
  let blacks = 0;
  if (s0 === g0) blacks++; else { scratch[s0]++; scratch[6 + g0]++; }
  if (s1 === g1) blacks++; else { scratch[s1]++; scratch[6 + g1]++; }
  if (s2 === g2) blacks++; else { scratch[s2]++; scratch[6 + g2]++; }
  if (s3 === g3) blacks++; else { scratch[s3]++; scratch[6 + g3]++; }
  let whites = 0;
  for (let c = 0; c < 6; c++) {
    const a = scratch[c], b = scratch[6 + c];
    whites += a < b ? a : b;
  }
  return blacks * 16 + whites;
}

const JS_IMPLS = {
  "js naive (4 allocs/call)": jsNaive,
  "js tuned switch (010's figure)": jsTunedSwitch,
  "js bit-packed nibbles": jsBitpacked,
  "js typed-array scratch": jsTypedScratch,
};

async function main() {
  const oz = await loadWasm(OZ);
  const o3 = await loadWasm(O3);
  console.log(`instantiate: -Oz ${oz.instantiateMs.toFixed(3)} ms, -O3 ${o3.instantiateMs.toFixed(3)} ms\n`);

  const wasmScore = o3.instance.exports.score_guess;

  // ─── Parity: every JS formulation must match WASM on every pair ─────────
  console.log(`parity check (${codes.length} x ${codes.length} = ${(codes.length * codes.length).toLocaleString()} pairs)...`);
  for (const [name, fn] of Object.entries(JS_IMPLS)) {
    for (const g of codes) {
      for (const s of codes) {
        const w = wasmScore(s[0], s[1], s[2], s[3], g[0], g[1], g[2], g[3]);
        const j = fn(s[0], s[1], s[2], s[3], g[0], g[1], g[2], g[3]);
        if (w !== j) {
          console.error(`PARITY FAIL: ${name} secret=${s} guess=${g} wasm=${w} js=${j}`);
          process.exit(1);
        }
      }
    }
  }
  console.log("  all formulations match WASM bit-for-bit\n");

  // ─── Timed runs: full 1296x1296 = 1,679,616 calls per round ────────────
  function fullSweep(fn) {
    let acc = 0;
    for (const g of codes) for (const s of codes) acc += fn(s[0], s[1], s[2], s[3], g[0], g[1], g[2], g[3]);
    return acc;
  }

  const results = {};
  results["WASM -Oz"] = timeRounds(() => fullSweep(oz.instance.exports.score_guess));
  results["WASM -O3"] = timeRounds(() => fullSweep(wasmScore));
  for (const [name, fn] of Object.entries(JS_IMPLS)) {
    results[name] = timeRounds(() => fullSweep(fn));
  }

  const wasmMed = Math.min(results["WASM -Oz"].med, results["WASM -O3"].med);
  console.log(`${codes.length * codes.length} calls per round, 5 warmup + 7 timed rounds, median + [min, max] reported:\n`);
  for (const [name, stat] of Object.entries(results)) {
    console.log(fmtRow(name, stat, wasmMed));
  }

  const bestJsName = Object.entries(JS_IMPLS)
    .map(([name]) => name)
    .reduce((best, name) => (results[name].med < results[best].med ? name : best));
  const bestJs = results[bestJsName];
  console.log(`\nbest JS formulation: "${bestJsName}" @ ${bestJs.med.toFixed(3)} ms median`);
  console.log(`WASM (best of -Oz/-O3) @ ${wasmMed.toFixed(3)} ms median`);
  console.log(`ratio: ${(bestJs.med / wasmMed).toFixed(2)}x (010's published figure was 1.68x using "js tuned switch")`);
}

main();
