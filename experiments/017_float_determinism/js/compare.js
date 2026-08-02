#!/usr/bin/env node
// Parses the CSV captures in results/*.csv (one per host, produced by run_matrix.sh)
// and prints the cross-engine divergence matrix: for every function, how many of N
// inputs disagree between hosts, the max ULP delta, and a cheap fingerprint hash over
// all result bits. This is the thing that turns "not identical" into a real finding.
//
// Usage: node js/compare.js results/
"use strict";

const fs = require("fs");
const path = require("path");

const resultsDir = process.argv[2] || "results";

const FUNCTIONS = [
  { name: "add", arity: 2, kind: "basic" },
  { name: "sub", arity: 2, kind: "basic" },
  { name: "mul", arity: 2, kind: "basic" },
  { name: "div", arity: 2, kind: "basic" },
  { name: "sqrt", arity: 1, kind: "basic" },
  { name: "sin", arity: 1, kind: "trig" },
  { name: "cos", arity: 1, kind: "trig" },
  { name: "tan", arity: 1, kind: "trig" },
  { name: "pow", arity: 2, kind: "trig" },
  { name: "exp", arity: 1, kind: "trig" },
  { name: "log", arity: 1, kind: "trig" },
];

// host key -> { label, jsRowSupported }
const HOST_FILES = {
  node: { file: "node.csv", label: "node (V8)", hasJs: true, hasWasm: true },
  jsc: { file: "jsc.csv", label: "jsc (JavaScriptCore)", hasJs: true, hasWasm: true },
  spidermonkey: { file: "spidermonkey.csv", label: "js (SpiderMonkey)", hasJs: true, hasWasm: true },
  bun: { file: "bun.csv", label: "bun (JavaScriptCore)", hasJs: true, hasWasm: true },
  wasmtime: { file: "wasmtime.csv", label: "wasmtime (no JS)", hasJs: false, hasWasm: true },
};

function parseCsv(text, defaultImpl) {
  // rows[impl][func] = array indexed by idx -> { aHex, bHex, resultHex }
  const rows = {};
  for (const line of text.split("\n")) {
    if (!line || line.startsWith("#") || line.startsWith("impl,") || line.startsWith("func,")) continue;
    const parts = line.split(",");
    let impl, func, idx, aHex, bHex, resultHex;
    if (defaultImpl) {
      // wasmtime driver format: func,idx,a_hex,b_hex,result_hex
      [func, idx, aHex, bHex, resultHex] = parts;
      impl = defaultImpl;
    } else {
      // battery.js format: impl,func,idx,a_hex,b_hex,result_hex
      [impl, func, idx, aHex, bHex, resultHex] = parts;
    }
    if (!rows[impl]) rows[impl] = {};
    if (!rows[impl][func]) rows[impl][func] = [];
    rows[impl][func][Number(idx)] = { aHex, bHex, resultHex };
  }
  return rows;
}

function loadHost(key) {
  const meta = HOST_FILES[key];
  const p = path.join(resultsDir, meta.file);
  if (!fs.existsSync(p)) return null;
  const text = fs.readFileSync(p, "utf8");
  const defaultImpl = key === "wasmtime" ? "wasm" : null;
  return { key, meta, rows: parseCsv(text, defaultImpl) };
}

const hosts = Object.keys(HOST_FILES).map(loadHost).filter(Boolean);
if (hosts.length === 0) {
  console.error(`No result CSVs found in ${resultsDir}/`);
  process.exit(1);
}

// ─── bit-pattern helpers ────────────────────────────────────────────────────────

function bitsFromHex(hex) {
  return BigInt("0x" + hex);
}

function isNaNBits(bits) {
  const exp = (bits >> 52n) & 0x7ffn;
  const mantissa = bits & 0xfffffffffffffn;
  return exp === 0x7ffn && mantissa !== 0n;
}

function orderedKey(bits) {
  const SIGNBIT = 1n << 63n;
  const MASK64 = (1n << 64n) - 1n;
  return (bits & SIGNBIT) ? (~bits & MASK64) : (bits | SIGNBIT);
}

function ulpDistance(bitsA, bitsB) {
  const ka = orderedKey(bitsA);
  const kb = orderedKey(bitsB);
  return ka > kb ? ka - kb : kb - ka;
}

// FNV-1a over all result hex strings for a (host, impl, func) — a cheap fingerprint,
// not a security hash. Two hosts with the same fingerprint agree on every sample.
function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}

function fingerprint(rowsForFunc) {
  if (!rowsForFunc) return null;
  return fnv1a(rowsForFunc.map((r) => r.resultHex).join(","));
}

// ─── comparison ─────────────────────────────────────────────────────────────────

function compareRows(refRows, otherRows) {
  const n = Math.max(refRows.length, otherRows.length);
  let differing = 0;
  let maxUlp = 0n;
  let nanMismatch = 0;
  for (let i = 0; i < n; i++) {
    const r = refRows[i];
    const o = otherRows[i];
    if (!r || !o) continue;
    if (r.resultHex === o.resultHex) continue;
    const rb = bitsFromHex(r.resultHex);
    const ob = bitsFromHex(o.resultHex);
    const rNaN = isNaNBits(rb);
    const oNaN = isNaNBits(ob);
    if (rNaN && oNaN) {
      nanMismatch++; // both NaN, different payload bits — not a numeric ULP difference
      continue;
    }
    if (rNaN !== oNaN) {
      differing++; // one is NaN, the other isn't — genuine disagreement
      continue;
    }
    differing++;
    const d = ulpDistance(rb, ob);
    if (d > maxUlp) maxUlp = d;
  }
  return { differing, maxUlp, nanMismatch, n };
}

function printSection(title, impl, engineHosts, refKey) {
  console.log("");
  console.log(`## ${title}`);
  console.log("");
  const ref = engineHosts.find((h) => h.key === refKey) || engineHosts[0];
  const others = engineHosts.filter((h) => h !== ref);
  if (!ref || others.length === 0) {
    console.log("  (not enough hosts captured to compare)");
    return;
  }
  console.log(`  reference: ${ref.meta.label}`);
  console.log("");
  const header = ["function", ...others.map((h) => h.meta.label)];
  console.log("  " + header.join(" | "));
  for (const spec of FUNCTIONS) {
    const refRows = (ref.rows[impl] && ref.rows[impl][spec.name]) || [];
    if (refRows.length === 0) continue;
    const cells = [spec.name];
    for (const h of others) {
      const otherRows = (h.rows[impl] && h.rows[impl][spec.name]) || [];
      if (otherRows.length === 0) {
        cells.push("n/a");
        continue;
      }
      const { differing, maxUlp, nanMismatch, n } = compareRows(refRows, otherRows);
      const pct = n ? ((differing / n) * 100).toFixed(1) : "0.0";
      let cell = differing === 0 ? "identical" : `${differing}/${n} (${pct}%), max ${maxUlp} ULP`;
      if (nanMismatch > 0) cell += `, ${nanMismatch} NaN-payload diffs`;
      cells.push(cell);
    }
    console.log("  " + cells.join(" | "));
  }
}

function printFingerprints(impl, engineHosts) {
  console.log("");
  console.log(`## Fingerprints (${impl}) — same value = bit-identical across every sample`);
  console.log("");
  for (const spec of FUNCTIONS) {
    const row = [spec.name];
    for (const h of engineHosts) {
      const fp = fingerprint((h.rows[impl] && h.rows[impl][spec.name]) || null);
      row.push(`${h.key}=${fp || "n/a"}`);
    }
    console.log("  " + row.join("  "));
  }
}

console.log(`Hosts captured: ${hosts.map((h) => h.key).join(", ")}`);

const jsHosts = hosts.filter((h) => h.meta.hasJs);
const wasmHosts = hosts.filter((h) => h.meta.hasWasm);

printSection("JS row — Math.* transcendentals & arithmetic (H1 / H3 control)", "js", jsHosts, "node");
printFingerprints("js", jsHosts);

printSection("WASM row — same .wasm module via each host (H2 / H3 control)", "wasm", wasmHosts, "node");
printFingerprints("wasm", wasmHosts);

// ─── hypothesis verdicts (mechanical, from the numbers above) ──────────────────

console.log("");
console.log("## Hypothesis verdicts (derived from the tables above)");
console.log("");

function allIdentical(impl, funcNames, engineHosts, refKey) {
  const ref = engineHosts.find((h) => h.key === refKey) || engineHosts[0];
  const others = engineHosts.filter((h) => h !== ref);
  if (!ref || others.length === 0) return null;
  for (const name of funcNames) {
    const refRows = (ref.rows[impl] && ref.rows[impl][name]) || [];
    if (refRows.length === 0) continue;
    for (const h of others) {
      const otherRows = (h.rows[impl] && h.rows[impl][name]) || [];
      if (otherRows.length === 0) continue;
      const { differing } = compareRows(refRows, otherRows);
      if (differing > 0) return false;
    }
  }
  return true;
}

const trigNames = FUNCTIONS.filter((f) => f.kind === "trig").map((f) => f.name);
const basicNames = FUNCTIONS.filter((f) => f.kind === "basic").map((f) => f.name);

const h1 = allIdentical("js", trigNames, jsHosts, "node");
const h2 = allIdentical("wasm", trigNames, wasmHosts, "node");
const h3js = allIdentical("js", basicNames, jsHosts, "node");
const h3wasm = allIdentical("wasm", basicNames, wasmHosts, "node");

console.log(`  H1 (JS transcendentals bit-identical across engines): ${h1 === null ? "INCONCLUSIVE (not enough hosts)" : h1 ? "CONFIRMED (unexpected — report honestly)" : "REJECTED (divergence found, as expected)"}`);
console.log(`  H2 (WASM transcendentals bit-identical across all hosts incl. wasmtime): ${h2 === null ? "INCONCLUSIVE (not enough hosts)" : h2 ? "CONFIRMED" : "REJECTED"}`);
console.log(`  H3 (basic arithmetic bit-identical, JS and WASM, control): JS=${h3js === null ? "n/a" : h3js}, WASM=${h3wasm === null ? "n/a" : h3wasm}`);
console.log(`  H4 (mechanism — bundled libm, not instruction guarantee): see build output / README (zero imports + size delta), not a numeric comparison`);
