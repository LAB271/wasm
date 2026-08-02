// Axis 2 — work per crossing. Same TOTAL number of score_guess pairs scored
// throughout; only how many are grouped into a single WASM call (the
// "granularity" K) varies, from K=1 (one call per pair, 010's original
// shape) to K=TOTAL (one call, everything at once).
//
// Because TOTAL is held fixed, total round time as a function of the number
// of *calls* C = TOTAL/K is a straight line: time = a + b*C. `b` is the
// per-crossing (per-call) overhead; `a` is the pure-compute time you'd pay
// even with zero crossings — i.e. what one giant call costs. That split is
// the decomposition the brief asks for, done with actual regression instead
// of eyeballing a curve.
import { loadWasm, writeI32Array, timeRounds, olsFit } from "./common.mjs";

const TOTAL = 1_048_576; // 2^20 — divisible by every granularity below
const GRANULARITIES = [1, 2, 4, 8, 16, 64, 256, 1024, 4096, 16384, 65536, 262144, 1048576];

function genPairs(n) {
  const secrets = new Int32Array(n * 4);
  const guesses = new Int32Array(n * 4);
  let s = 12345;
  const next = () => {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return s;
  };
  for (let i = 0; i < n * 4; i++) {
    secrets[i] = next() % 6;
    guesses[i] = next() % 6;
  }
  return { secrets, guesses };
}

function jsBitpacked(s0, s1, s2, s3, g0, g1, g2, g3) {
  let blacks = 0, sBits = 0, gBits = 0;
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

async function main() {
  const { instance } = await loadWasm("output/crossover_o3.wasm");
  const exp = instance.exports;
  const { secrets, guesses } = genPairs(TOTAL);

  exp.reset_arena();
  const secretsPtr = writeI32Array(instance, secrets);
  const guessesPtr = writeI32Array(instance, guesses);
  const outPtr = exp.alloc(TOTAL * 4);

  // ─── Parity: one full-batch WASM call vs JS, spot-checked ────────────────
  exp.score_guess_batch(secretsPtr, guessesPtr, TOTAL, outPtr);
  const out = new Int32Array(instance.exports.memory.buffer, outPtr, TOTAL);
  for (let i = 0; i < TOTAL; i += 104729) {
    // sparse spot-check (prime stride) rather than all 1M, this is just a
    // sanity gate — bench_010_rematch.mjs is the exhaustive parity check.
    const b = i * 4;
    const want = jsBitpacked(secrets[b], secrets[b + 1], secrets[b + 2], secrets[b + 3], guesses[b], guesses[b + 1], guesses[b + 2], guesses[b + 3]);
    if (out[i] !== want) {
      console.error(`PARITY FAIL at ${i}: wasm=${out[i]} js=${want}`);
      process.exit(1);
    }
  }
  console.log("parity ok (spot-checked)\n");

  console.log(`=== Axis 2: granularity sweep, TOTAL=${TOTAL.toLocaleString()} pairs fixed ===\n`);
  console.log("K".padStart(10), "calls".padStart(10), "median ms".padStart(12), "ns/element".padStart(12));

  const points = []; // [num_calls, ms] for the OLS fit
  const rows = []; // [K, num_calls, ms] for direct crossover lookup
  for (const K of GRANULARITIES) {
    const calls = TOTAL / K;
    const stat = timeRounds(
      () => {
        for (let c = 0; c < calls; c++) {
          exp.score_guess_batch(secretsPtr + c * K * 16, guessesPtr + c * K * 16, K, outPtr + c * K * 4);
        }
        return calls;
      },
      { warmup: 2, timed: 5 }
    );
    points.push([calls, stat.med]);
    rows.push([K, calls, stat.med]);
    console.log(
      String(K).padStart(10),
      String(calls).padStart(10),
      stat.med.toFixed(4).padStart(12),
      ((stat.med / TOTAL) * 1e6).toFixed(2).padStart(12)
    );
  }

  const { a, b, r2 } = olsFit(points);
  console.log(`\nOLS fit: round_ms = ${a.toFixed(5)} + ${b.toExponential(3)} * num_calls  (R^2 = ${r2.toFixed(4)}, ${points.length} granularities)`);
  console.log(`  per-crossing (WASM call) overhead: ${(b * 1e6).toFixed(1)} ns/call`);
  console.log(`  fitted pure-compute time @ ${TOTAL.toLocaleString()} elements (calls->~0): ${a.toFixed(4)} ms`);
  console.log(`  => per-element compute cost:        ${((a / TOTAL) * 1e6).toFixed(2)} ns/element`);
  if (r2 < 0.9) {
    console.log(`  NOTE: R^2 < 0.9 — the line is a rough guide, not a precise fit. See the raw table for what actually happened at the extremes.`);
  }

  const jsStat = timeRounds(() => {
    let acc = 0;
    for (let i = 0; i < TOTAL; i++) {
      const b = i * 4;
      acc += jsBitpacked(secrets[b], secrets[b + 1], secrets[b + 2], secrets[b + 3], guesses[b], guesses[b + 1], guesses[b + 2], guesses[b + 3]);
    }
    return acc;
  });
  console.log(`\njs bit-packed, flat loop over all ${TOTAL.toLocaleString()} pairs (no crossing to amortize):`);
  console.log(`  ${jsStat.med.toFixed(4)} ms  (~${((jsStat.med / TOTAL) * 1e6).toFixed(2)} ns/element)`);

  // Crossover, read directly off the measured table (not the OLS line, which
  // can miss curvature at the extremes) — first K (ascending) whose measured
  // WASM round time beats the flat JS baseline.
  const firstWin = rows.find(([, , ms]) => ms <= jsStat.med);
  if (!firstWin) {
    console.log(`\nWASM never beat this JS formulation anywhere in the sweep (worst JS-relative row: ${(Math.min(...rows.map(([, , ms]) => ms)) / jsStat.med).toFixed(2)}x at best).`);
  } else {
    const [kWin, callsWin, msWin] = firstWin;
    console.log(`\ncrossover (measured): WASM batching beats this JS formulation once granularity K >= ${kWin.toLocaleString()} (<= ${callsWin.toLocaleString()} calls), ${msWin.toFixed(4)} ms vs JS's ${jsStat.med.toFixed(4)} ms.`);
    console.log(`At K=1 (010's original per-call shape): ${rows[0][2].toFixed(4)} ms, ${(rows[0][2] / jsStat.med).toFixed(2)}x slower than this JS formulation.`);
  }
}

main();
