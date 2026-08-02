// Cross-engine leg of the 010 rematch — plain classic script (no import/
// export), runnable unmodified under node, jsc, spidermonkey `js`, and bun.
// Reuses the portability pattern from experiment 017's js/battery.js
// (portable readBinary + print shims, performance.now() for timing since
// it's the one high-res timer all four engines actually expose).
//
// Scope: scalar score_guess only (rung 1) — the cheapest, most portable
// axis, and the one 010's published number is about. The rest of Axis 1/2
// stay Node+browser only (see README "engine coverage" note).
(function () {
  "use strict";

  function out(s) {
    if (typeof console !== "undefined" && console.log) { console.log(s); return; }
    if (typeof print === "function") { print(s); return; }
    throw new Error("no output function available in this engine");
  }

  function readBinary(path) {
    if (typeof require === "function") return require("fs").readFileSync(path); // node, bun
    if (typeof os !== "undefined" && os.file && typeof os.file.readFile === "function") return os.file.readFile(path, "binary"); // spidermonkey js
    if (typeof readFile === "function") return readFile(path, "binary"); // jsc
    throw new Error("no binary file reader available in this engine");
  }

  const WASM_PATH = "output/crossover_o3.wasm";
  const N = 300; // codes sliced to 300 x 1296 = 388,800 pairs — enough to be
  // measurable on a slower interpreter without a multi-second run.

  const codes = [];
  for (let a = 0; a < 6; a++) for (let b = 0; b < 6; b++) for (let c = 0; c < 6; c++) for (let d = 0; d < 6; d++) codes.push([a, b, c, d]);
  const guessSample = codes.slice(0, N);

  function jsTunedSwitch(s0, s1, s2, s3, g0, g1, g2, g3) {
    let b = 0, a0 = 0, a1 = 0, a2 = 0, a3 = 0, a4 = 0, a5 = 0, b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0;
    if (s0 === g0) b++; else { switch (s0) { case 0: a0++; break; case 1: a1++; break; case 2: a2++; break; case 3: a3++; break; case 4: a4++; break; default: a5++; } switch (g0) { case 0: b0++; break; case 1: b1++; break; case 2: b2++; break; case 3: b3++; break; case 4: b4++; break; default: b5++; } }
    if (s1 === g1) b++; else { switch (s1) { case 0: a0++; break; case 1: a1++; break; case 2: a2++; break; case 3: a3++; break; case 4: a4++; break; default: a5++; } switch (g1) { case 0: b0++; break; case 1: b1++; break; case 2: b2++; break; case 3: b3++; break; case 4: b4++; break; default: b5++; } }
    if (s2 === g2) b++; else { switch (s2) { case 0: a0++; break; case 1: a1++; break; case 2: a2++; break; case 3: a3++; break; case 4: a4++; break; default: a5++; } switch (g2) { case 0: b0++; break; case 1: b1++; break; case 2: b2++; break; case 3: b3++; break; case 4: b4++; break; default: b5++; } }
    if (s3 === g3) b++; else { switch (s3) { case 0: a0++; break; case 1: a1++; break; case 2: a2++; break; case 3: a3++; break; case 4: a4++; break; default: a5++; } switch (g3) { case 0: b0++; break; case 1: b1++; break; case 2: b2++; break; case 3: b3++; break; case 4: b4++; break; default: b5++; } }
    return b * 16 + ((a0 < b0 ? a0 : b0) + (a1 < b1 ? a1 : b1) + (a2 < b2 ? a2 : b2) + (a3 < b3 ? a3 : b3) + (a4 < b4 ? a4 : b4) + (a5 < b5 ? a5 : b5));
  }

  function jsBitpacked(s0, s1, s2, s3, g0, g1, g2, g3) {
    let blacks = 0, sBits = 0, gBits = 0;
    if (s0 === g0) blacks++; else { sBits += 1 << (s0 * 4); gBits += 1 << (g0 * 4); }
    if (s1 === g1) blacks++; else { sBits += 1 << (s1 * 4); gBits += 1 << (g1 * 4); }
    if (s2 === g2) blacks++; else { sBits += 1 << (s2 * 4); gBits += 1 << (g2 * 4); }
    if (s3 === g3) blacks++; else { sBits += 1 << (s3 * 4); gBits += 1 << (g3 * 4); }
    let whites = 0;
    for (let c = 0; c < 6; c++) { const sc = (sBits >>> (c * 4)) & 0xf, gc = (gBits >>> (c * 4)) & 0xf; whites += sc < gc ? sc : gc; }
    return blacks * 16 + whites;
  }

  function median(xs) { const s = xs.slice().sort(function (a, b) { return a - b; }); const m = Math.floor(s.length / 2); return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; }

  function run(fn, label) {
    const rounds = [];
    let lastAcc = 0;
    for (let w = 0; w < 3; w++) { let x = 0; for (let gi = 0; gi < guessSample.length; gi++) { const g = guessSample[gi]; for (let ci = 0; ci < codes.length; ci++) { const s = codes[ci]; x += fn(s[0], s[1], s[2], s[3], g[0], g[1], g[2], g[3]); } } }
    for (let r = 0; r < 5; r++) {
      const t0 = performance.now();
      let acc = 0;
      for (let gi = 0; gi < guessSample.length; gi++) { const g = guessSample[gi]; for (let ci = 0; ci < codes.length; ci++) { const s = codes[ci]; acc += fn(s[0], s[1], s[2], s[3], g[0], g[1], g[2], g[3]); } }
      rounds.push(performance.now() - t0);
      lastAcc = acc;
    }
    out(label + "," + median(rounds).toFixed(4) + "," + lastAcc);
    return median(rounds);
  }

  out("impl,median_ms,checksum");

  const pairCount = guessSample.length * codes.length;
  out("# pairs_per_round=" + pairCount);

  const tunedMs = run(jsTunedSwitch, "js_tuned_switch");
  const bitMs = run(jsBitpacked, "js_bitpacked");

  try {
    const bytes = readBinary(WASM_PATH);
    const mod = new WebAssembly.Module(bytes);
    const inst = new WebAssembly.Instance(mod, {});
    const scoreGuess = inst.exports.score_guess;

    // parity spot-check
    for (let gi = 0; gi < guessSample.length; gi += 37) {
      const g = guessSample[gi];
      for (let ci = 0; ci < codes.length; ci += 41) {
        const s = codes[ci];
        const w = scoreGuess(s[0], s[1], s[2], s[3], g[0], g[1], g[2], g[3]);
        const j = jsBitpacked(s[0], s[1], s[2], s[3], g[0], g[1], g[2], g[3]);
        if (w !== j) { out("# PARITY FAIL s=" + s + " g=" + g + " wasm=" + w + " js=" + j); throw new Error("parity"); }
      }
    }

    const wasmMs = run(scoreGuess, "wasm");
    out("# ratio wasm_vs_tuned_switch=" + (tunedMs / wasmMs).toFixed(3));
    out("# ratio wasm_vs_bitpacked=" + (bitMs / wasmMs).toFixed(3));
  } catch (e) {
    out("# WASM leg failed: " + (e && e.message ? e.message : e));
  }
})();
