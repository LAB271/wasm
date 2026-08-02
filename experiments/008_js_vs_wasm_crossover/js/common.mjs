// Shared helpers for the Node-hosted benchmarks (bench_axis1.mjs,
// bench_axis2.mjs, bench_010_rematch.mjs). Node-only (uses
// process.hrtime.bigint + node:fs) — the portable multi-engine script
// (js/portable_battery.mjs) is deliberately self-contained instead, since jsc
// and the spidermonkey `js` shell don't share Node's API surface.
import { readFileSync } from "node:fs";

export async function loadWasm(path) {
  const bytes = readFileSync(path);
  const t0 = process.hrtime.bigint();
  const { instance, module } = await WebAssembly.instantiate(bytes, {});
  const t1 = process.hrtime.bigint();
  return { instance, module, bytes, instantiateMs: Number(t1 - t0) / 1e6 };
}

// ─── Linear-memory marshalling helpers ─────────────────────────────────────
// Every one of these calls the module's bump allocator, then writes through
// a fresh typed-array view (memory can be detached/regrown by `alloc`, so the
// view must be created AFTER the alloc call, never cached across it).

export function writeI32Array(instance, arr) {
  const ptr = instance.exports.alloc(arr.length * 4);
  new Int32Array(instance.exports.memory.buffer, ptr, arr.length).set(arr);
  return ptr;
}

export function writeF64Array(instance, arr) {
  const ptr = instance.exports.alloc(arr.length * 8);
  new Float64Array(instance.exports.memory.buffer, ptr, arr.length).set(arr);
  return ptr;
}

export function writeBytes(instance, u8) {
  const ptr = instance.exports.alloc(u8.length);
  new Uint8Array(instance.exports.memory.buffer, ptr, u8.length).set(u8);
  return ptr;
}

export function readI32Array(instance, ptr, len) {
  // Copy out (not a live view) so results survive a subsequent alloc/grow.
  return new Int32Array(instance.exports.memory.buffer, ptr, len).slice();
}

const encoder = new TextEncoder();
export function encodeUtf8(str) {
  return encoder.encode(str);
}

// ─── Timing / stats ─────────────────────────────────────────────────────────

export function nowMs() {
  return Number(process.hrtime.bigint()) / 1e6;
}

export function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

export function spread(xs) {
  return { min: Math.min(...xs), max: Math.max(...xs) };
}

/// Runs `fn()` `warmup` times (discarded) then `timed` times, returning the
/// array of per-round millisecond durations. `fn` must return a numeric
/// checksum; it is accumulated and returned too so nothing gets dead-code
/// eliminated and callers can assert parity against a reference checksum.
export function timeRounds(fn, { warmup = 5, timed = 7 } = {}) {
  for (let i = 0; i < warmup; i++) fn();
  const ms = [];
  let checksum = 0;
  for (let i = 0; i < timed; i++) {
    const t0 = nowMs();
    checksum += fn();
    ms.push(nowMs() - t0);
  }
  return { ms, checksum, med: median(ms), ...spread(ms) };
}

export function fmtRow(label, stat, refMed) {
  const ratio = refMed != null ? ` ${(stat.med / refMed).toFixed(2)}x` : "";
  return `${label.padEnd(28)} med ${stat.med.toFixed(3).padStart(9)} ms   [${stat.min.toFixed(3)}, ${stat.max.toFixed(3)}]${ratio}`;
}

/// Ordinary-least-squares fit of y = a + b*x. Used to decompose a granularity
/// sweep's (elements, ms) points into a fixed per-call cost `a` (the
/// crossing/instantiation-independent overhead) and a per-element cost `b`
/// (marshalling + compute, lumped — callers subtract a separately-measured
/// pure-compute slope to split the two further; see README).
export function olsFit(points) {
  const n = points.length;
  const sx = points.reduce((s, [x]) => s + x, 0);
  const sy = points.reduce((s, [, y]) => s + y, 0);
  const sxx = points.reduce((s, [x]) => s + x * x, 0);
  const sxy = points.reduce((s, [x, y]) => s + x * y, 0);
  const b = (n * sxy - sx * sy) / (n * sxx - sx * sx);
  const a = (sy - b * sx) / n;
  const meanY = sy / n;
  const ssTot = points.reduce((s, [, y]) => s + (y - meanY) ** 2, 0);
  const ssRes = points.reduce((s, [x, y]) => s + (y - (a + b * x)) ** 2, 0);
  const r2 = ssTot === 0 ? 1 : 1 - ssRes / ssTot;
  return { a, b, r2 };
}
