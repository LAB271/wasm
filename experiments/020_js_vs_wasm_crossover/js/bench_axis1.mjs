// Axis 1 — what crosses the boundary. Rung 1 (scalars) is covered by
// bench_010_rematch.mjs; this covers rungs 2-5: typed arrays, plain arrays,
// strings, objects/structs. Same underlying task per rung (sum/hash), swept
// across sizes, so the marshalling-vs-compute decomposition holds together.
//
// For every rung we report THREE numbers, not one:
//   marshal   — cost of getting JS-native data into the shape WASM needs
//   wasm call — the compute itself, once data is already in linear memory
//   js native — the equivalent JS-only computation, no crossing at all
// "wasm total" = marshal + wasm call, the number that actually competes
// against "js native".
import { loadWasm, writeF64Array, writeBytes, timeRounds, fmtRow, encodeUtf8 } from "./common.mjs";

const SIZES = [1_000, 100_000, 2_000_000];

function mkFloats(n, seed = 1) {
  const a = new Array(n);
  let s = seed;
  for (let i = 0; i < n; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    a[i] = (s % 2000) / 10 - 100; // [-100, 100)
  }
  return a;
}

function mkString(n) {
  const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,!?";
  let s = "";
  // Chunked build (avoid O(n^2) string concat) via array join.
  const parts = new Array(Math.ceil(n / 32));
  for (let i = 0; i < parts.length; i++) {
    let chunk = "";
    for (let j = 0; j < 32; j++) chunk += alphabet[(i * 32 + j) % alphabet.length];
    parts[i] = chunk;
  }
  s = parts.join("").slice(0, n);
  return s;
}

function jsSumFloats(arr) {
  let acc = 0;
  for (let i = 0; i < arr.length; i++) acc += arr[i];
  return acc;
}

function jsHashUtf16(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

function jsSumPoints(points) {
  let acc = 0;
  for (let i = 0; i < points.length; i++) {
    const p = points[i];
    acc += Math.sqrt(p.x * p.x + p.y * p.y);
  }
  return acc;
}

function jsSumPointsSq(points) {
  let acc = 0;
  for (let i = 0; i < points.length; i++) {
    const p = points[i];
    acc += p.x * p.x + p.y * p.y;
  }
  return acc;
}

async function main() {
  const { instance } = await loadWasm("output/crossover_o3.wasm");
  const exp = instance.exports;

  console.log("=== Axis 1: what crosses the boundary ===\n");

  for (const n of SIZES) {
    console.log(`--- N = ${n.toLocaleString()} ---`);

    // Rung 2/3: typed array vs plain array (same "sum of floats" task) ----
    exp.reset_arena();
    const plainArr = mkFloats(n);
    const typedArr = Float64Array.from(plainArr);

    const rMarshal = timeRounds(() => {
      exp.reset_arena();
      const ptr = writeF64Array(instance, typedArr);
      return ptr; // not a real checksum, fine — parity is checked separately below
    });
    const rWasmCall = (() => {
      exp.reset_arena();
      const ptr = writeF64Array(instance, typedArr);
      return timeRounds(() => exp.sum_f64(ptr, n));
    })();
    const rJsTyped = timeRounds(() => jsSumFloats(typedArr));
    const rJsPlain = timeRounds(() => jsSumFloats(plainArr));

    // parity
    exp.reset_arena();
    const ptr0 = writeF64Array(instance, typedArr);
    const wasmSum = exp.sum_f64(ptr0, n);
    const jsSum = jsSumFloats(typedArr);
    if (Math.abs(wasmSum - jsSum) > Math.abs(jsSum) * 1e-9 + 1e-6) {
      console.error(`  PARITY FAIL sum: wasm=${wasmSum} js=${jsSum}`);
      process.exit(1);
    }

    console.log("  [floats] " + fmtRow("marshal (F64Array->linmem)", rMarshal));
    console.log("  [floats] " + fmtRow("wasm call only (post-marshal)", rWasmCall));
    console.log(
      "  [floats] " +
        fmtRow("wasm TOTAL (marshal+call)", { med: rMarshal.med + rWasmCall.med, min: rMarshal.min + rWasmCall.min, max: rMarshal.max + rWasmCall.max })
    );
    console.log("  [floats] " + fmtRow("js native, typed array", rJsTyped));
    console.log("  [floats] " + fmtRow("js native, plain array", rJsPlain));

    // Rung 4: strings ------------------------------------------------------
    const str = mkString(n);
    let utf8;
    const rEncode = timeRounds(() => {
      utf8 = encodeUtf8(str);
      return utf8.length;
    });
    const rHashCall = (() => {
      exp.reset_arena();
      const ptr = writeBytes(instance, utf8);
      return timeRounds(() => exp.hash_bytes(ptr, utf8.length));
    })();
    const rJsHash = timeRounds(() => jsHashUtf16(str));

    console.log("  [string] " + fmtRow("marshal (UTF16->UTF8 encode)", rEncode));
    console.log("  [string] " + fmtRow("wasm call only (post-encode)", rHashCall));
    console.log(
      "  [string] " +
        fmtRow("wasm TOTAL (encode+call)", { med: rEncode.med + rHashCall.med, min: rEncode.min + rHashCall.min, max: rEncode.max + rHashCall.max })
    );
    console.log("  [string] " + fmtRow("js native (UTF-16 charCodeAt)", rJsHash));

    // Rung 5: objects/structs ------------------------------------------------
    const points = [];
    for (let i = 0; i < n; i++) points.push({ x: plainArr[i], y: plainArr[(i + 1) % n] });

    const rExtract = timeRounds(() => {
      const xs = new Float64Array(n);
      const ys = new Float64Array(n);
      for (let i = 0; i < n; i++) {
        xs[i] = points[i].x;
        ys[i] = points[i].y;
      }
      return xs[0] + ys[0];
    });
    const rSumPointsCall = (() => {
      const xs = new Float64Array(n);
      const ys = new Float64Array(n);
      for (let i = 0; i < n; i++) {
        xs[i] = points[i].x;
        ys[i] = points[i].y;
      }
      exp.reset_arena();
      const xptr = writeF64Array(instance, xs);
      const yptr = writeF64Array(instance, ys);
      return timeRounds(() => exp.sum_points(xptr, yptr, n));
    })();
    const rJsPoints = timeRounds(() => jsSumPoints(points));

    // isolates marshalling from the sqrt-specific software-vs-hardware tax
    const rSumPointsSqCall = (() => {
      const xs = new Float64Array(n);
      const ys = new Float64Array(n);
      for (let i = 0; i < n; i++) {
        xs[i] = points[i].x;
        ys[i] = points[i].y;
      }
      exp.reset_arena();
      const xptr = writeF64Array(instance, xs);
      const yptr = writeF64Array(instance, ys);
      return timeRounds(() => exp.sum_points_sq(xptr, yptr, n));
    })();
    const rJsPointsSq = timeRounds(() => jsSumPointsSq(points));

    console.log("  [points] " + fmtRow("marshal (AoS objects->SoA typed)", rExtract));
    console.log("  [points] " + fmtRow("wasm call only (post-extract, w/ sqrt)", rSumPointsCall));
    console.log(
      "  [points] " +
        fmtRow("wasm TOTAL (extract+call, w/ sqrt)", { med: rExtract.med + rSumPointsCall.med, min: rExtract.min + rSumPointsCall.min, max: rExtract.max + rSumPointsCall.max })
    );
    console.log("  [points] " + fmtRow("js native (AoS, field access, w/ sqrt)", rJsPoints));
    console.log("  [points] " + fmtRow("wasm call only, NO sqrt (marshal isolation)", rSumPointsSqCall));
    console.log("  [points] " + fmtRow("js native, NO sqrt (marshal isolation)", rJsPointsSq));
    console.log("");
  }
}

main();
