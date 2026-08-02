// 020 leg 3 runner — wasm-bindgen, hosted by Node.
//
// wasm-bindgen emits a JS module, so this leg cannot be hosted by the wasmtime
// harness the other five legs share. That is a property of the strategy, not a
// harness shortcut: choosing wasm-bindgen chooses a JS host.
//
// Its numbers are therefore NOT directly comparable to the wasmtime numbers.
// What *is* comparable, and what this file is for: the marshal/compute split
// within the leg, the bytes copied, and the size of the generated glue.
//
// One variant per process, same as the Rust harness (see issue #52). Usage:
//   node bench_bindgen.mjs <op>          # op = callcost|str|list|map|set_bitset|set_sorted
//
// The workload is read from output/workload/, dumped by the Rust host, so both
// hosts benchmark byte-identical data and check the same reference checksums.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const WORK = join(HERE, "..", "output", "workload");
const wasm = await import(
  join(HERE, "..", "guests", "rust_bindgen", "pkg", "collections_bindgen.js")
);

// Node's readFileSync can return a Buffer that is a view into a larger pooled
// ArrayBuffer, so `.buffer` must be sliced at the view's own offset. Getting
// this wrong silently reads adjacent memory as data — which the parity gate
// caught immediately, and is a small live example of exactly the class of bug
// this whole experiment is about.
function rdBuf(name) {
  const b = readFileSync(join(WORK, name));
  return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
}

const ref = JSON.parse(readFileSync(join(WORK, "reference.json"), "utf8"));
const strings = readFileSync(join(WORK, "strings.txt"), "utf8").split("\n");
const list = new Uint32Array(rdBuf("list.bin"));
const mapKeys = readFileSync(join(WORK, "map_keys.txt"), "utf8").split("\n");
const mapVals = new Uint32Array(rdBuf("map_vals.bin"));
const mapProbes = readFileSync(join(WORK, "map_probes.txt"), "utf8").split("\n");
const setMembers = new Uint32Array(rdBuf("set_members.bin"));
const setProbes = new Uint32Array(rdBuf("set_probes.bin"));
const setWords = new BigUint64Array(rdBuf("set_words.bin"));

const WARMUP = 3;
const ROUNDS = 9;

function bench(fn) {
  for (let i = 0; i < WARMUP; i++) fn();
  const t = [];
  let last = 0n;
  for (let i = 0; i < ROUNDS; i++) {
    const a = process.hrtime.bigint();
    last = fn();
    t.push(Number(process.hrtime.bigint() - a));
  }
  t.sort((a, b) => a - b);
  return { median: t[t.length >> 1], min: t[0], max: t[t.length - 1], checksum: last };
}

// UTF-8 byte length, which is what the generated glue actually copies.
const enc = new TextEncoder();
const utf8len = (s) => enc.encode(s).length;

const op = process.argv[2];
let out;

if (op === "callcost") {
  // Fixed per-call cost of the generated glue, 1-char string, no real work.
  const r = bench(() => {
    let acc = 0n;
    for (let i = 0; i < strings.length; i++) acc += wasm.noop_str("x");
    return acc;
  });
  out = { op, bytes: 0, marshal: null, call: r, total: r, checksum: r.checksum, note: `${strings.length} calls, 1-char string` };
} else if (op === "str") {
  const bytes = strings.reduce((a, s) => a + utf8len(s), 0);
  const m = bench(() => {
    let acc = 0n;
    for (const s of strings) acc += wasm.noop_str(s);
    return acc;
  });
  const t = bench(() => {
    let acc = 0n;
    for (const s of strings) acc += wasm.str_stats(s);
    return acc;
  });
  const got = BigInt.asUintN(64, t.checksum);
  if (got !== BigInt(ref.str)) throw new Error(`str parity FAILED: ${got.toString(16)} != ${BigInt(ref.str).toString(16)}`);
  out = { op, bytes, marshal: m, call: sub(t, m), total: t, checksum: got, note: `${strings.length} strings, utf16->utf8 via TextEncoder` };
} else if (op === "list") {
  const m = bench(() => wasm.noop_list_u32(list));
  const t = bench(() => wasm.list_sum_u32(list));
  const got = BigInt.asUintN(64, t.checksum);
  if (got !== BigInt(ref.list)) throw new Error(`list parity FAILED: ${got.toString(16)}`);
  out = { op, bytes: list.length * 4, marshal: m, call: sub(t, m), total: t, checksum: got, note: `${list.length} u32` };
} else if (op === "map") {
  const bytes =
    mapKeys.reduce((a, s) => a + utf8len(s), 0) +
    mapProbes.reduce((a, s) => a + utf8len(s), 0) +
    mapVals.length * 4 +
    (mapKeys.length + mapProbes.length) * 8; // ptr+len array wasm-bindgen builds
  const m = bench(() => wasm.noop_map(mapKeys, mapVals, mapProbes));
  const t = bench(() => wasm.map_lookup_sorted(mapKeys, mapVals, mapProbes));
  const got = BigInt.asUintN(64, t.checksum);
  if (got !== BigInt(ref.map)) throw new Error(`map parity FAILED: ${got.toString(16)}`);
  out = { op, bytes, marshal: m, call: sub(t, m), total: t, checksum: got, note: `${mapKeys.length} entries / ${mapProbes.length} probes` };
} else if (op === "set_sorted" || op === "set_bitset") {
  const bitset = op === "set_bitset";
  const m = bench(() => wasm.noop_set(bitset ? new Uint32Array(setWords.length * 2) : setMembers, setProbes));
  const t = bench(() =>
    bitset ? wasm.set_count_bitset(setWords, setProbes) : wasm.set_count_sorted(setMembers, setProbes),
  );
  const got = BigInt.asUintN(64, t.checksum);
  if (got !== BigInt(ref.set)) throw new Error(`${op} parity FAILED: ${got}`);
  out = {
    op,
    bytes: (bitset ? setWords.length * 8 : setMembers.length * 4) + setProbes.length * 4,
    marshal: m,
    call: sub(t, m),
    total: t,
    checksum: got,
    note: bitset ? "bitset words" : "sorted members",
  };
} else {
  throw new Error(`unknown op ${op}`);
}

function sub(total, marshal) {
  return {
    median: Math.max(0, total.median - marshal.median),
    min: Math.max(0, total.min - marshal.max),
    max: Math.max(0, total.max - marshal.min),
  };
}

const fmt = (r) => (r === null ? "null" : `{"median_ns":${r.median},"min_ns":${r.min},"max_ns":${r.max}}`);
console.log(
  JSON.stringify(JSON.parse(
    `{"leg":"rust_bindgen","op":"${out.op}","bytes":${out.bytes},"marshal":${fmt(out.marshal)},"call":${fmt(out.call)},"total":${fmt(out.total)},"checksum":"${out.checksum}","note":"${out.note}"}`,
  )),
);
