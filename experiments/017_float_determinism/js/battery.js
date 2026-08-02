// Cross-engine test battery. Runs unmodified under node, jsc, spidermonkey `js`, and
// bun — deliberately a plain classic script (no `require`d modules, no import/export,
// no argv dependence) because jsc in particular doesn't reliably pass extra argv
// through to a script file, and there's no module-loader convention all four engines
// agree on. Everything needed lives in this one file.
//
// The PRNG / input-generation formulas below MUST match rust/compute/src/lib.rs
// exactly, operation for operation — that identity is what lets four independent
// process invocations (one per engine) derive byte-identical test inputs from the
// same seed, with no data file shared between them. See that file's doc comment for
// why this is safe (both sides use only the same exactly-specified IEEE-754 ops).
//
// Prints one CSV line per (impl, function, sample): `impl,func,idx,a_hex,b_hex,result_hex`
// `impl` is "js" (native Math.*) or "wasm" (the wasm32-unknown-unknown cdylib).
// js/compare.js consumes this format from every engine's captured stdout.

(function () {
  "use strict";

  // ─── Portable host shims ────────────────────────────────────────────────────────

  function out(s) {
    if (typeof console !== "undefined" && console.log) {
      console.log(s);
      return;
    }
    if (typeof print === "function") {
      print(s);
      return;
    }
    throw new Error("no output function available in this engine");
  }

  function readBinary(path) {
    if (typeof require === "function") {
      return require("fs").readFileSync(path); // node, bun
    }
    if (typeof os !== "undefined" && os.file && typeof os.file.readFile === "function") {
      return os.file.readFile(path, "binary"); // spidermonkey `js` shell
    }
    if (typeof readFile === "function") {
      return readFile(path, "binary"); // jsc
    }
    throw new Error("no binary file reader available in this engine");
  }

  // ─── PRNG — mirrors rust/compute/src/lib.rs::Xorshift32 exactly ────────────────

  const SEED_STRIDE = 0x9e3779b1;
  const BASE_SEED = 0xc0ffee;
  const BUCKET_SCALES = [1e-8, 10.0, 1e4, 1e8];

  function makeRng(seed) {
    let state = seed >>> 0 || 1;
    return function nextU32() {
      let x = state;
      x = (x ^ (x << 13)) >>> 0;
      x = (x ^ (x >>> 17)) >>> 0;
      x = (x ^ (x << 5)) >>> 0;
      state = x;
      return x;
    };
  }

  function seedFor(base, functionIndex) {
    // Mirrors u32::wrapping_add(base, u32::wrapping_mul(index, SEED_STRIDE)).
    // Every intermediate value here stays well under 2^53, so the multiply/add
    // themselves are exact in JS's float64 — only the final >>> 0 truncations
    // (mirroring Rust's mod-2^32 wraparound) actually discard anything.
    const product = (functionIndex * SEED_STRIDE) >>> 0;
    return (base + product) >>> 0;
  }

  function nextF64(rng) {
    const hi = rng();
    const lo = rng();
    const unit = hi / 4294967296; // hi / 2^32 — exact (power-of-two division)
    const sign = (lo & 1) === 1 ? -1 : 1;
    const bucket = (lo >>> 1) & 0b11;
    return sign * unit * BUCKET_SCALES[bucket];
  }

  function nextF64Scaled(rng, scale) {
    const hi = rng();
    const lo = rng();
    const unit = hi / 4294967296;
    const sign = (lo & 1) === 1 ? -1 : 1;
    return sign * unit * scale;
  }

  // ─── Bit-pattern formatting ─────────────────────────────────────────────────────

  const f64buf = new ArrayBuffer(8);
  const f64view = new Float64Array(f64buf);
  const u64view = new BigUint64Array(f64buf);

  function hexBits(f) {
    f64view[0] = f;
    return u64view[0].toString(16).padStart(16, "0");
  }

  // ─── Function battery — MUST match rust/wasm-driver/src/main.rs::FUNCTIONS ─────

  const N = 300;
  const WASM_PATH = "output/determinism_full.wasm";

  const FUNCTIONS = [
    { name: "add", arity: 2 },
    { name: "sub", arity: 2 },
    { name: "mul", arity: 2 },
    { name: "div", arity: 2 },
    { name: "sqrt", arity: 1 },
    { name: "sin", arity: 1 },
    { name: "cos", arity: 1 },
    { name: "tan", arity: 1 },
    { name: "pow", arity: 2 },
    { name: "exp", arity: 1 },
    { name: "log", arity: 1 },
  ];

  const JS_IMPL = {
    add: (a, b) => a + b,
    sub: (a, b) => a - b,
    mul: (a, b) => a * b,
    div: (a, b) => a / b,
    sqrt: (a) => Math.sqrt(a),
    sin: (a) => Math.sin(a),
    cos: (a) => Math.cos(a),
    tan: (a) => Math.tan(a),
    pow: (a, b) => Math.pow(a, b),
    exp: (a) => Math.exp(a),
    log: (a) => Math.log(a),
  };

  function runBattery(label, callFn) {
    for (let fi = 0; fi < FUNCTIONS.length; fi++) {
      const spec = FUNCTIONS[fi];
      const rng = makeRng(seedFor(BASE_SEED, fi));
      for (let idx = 0; idx < N; idx++) {
        const a = nextF64(rng);
        let b = 0;
        if (spec.name === "pow") {
          b = nextF64Scaled(rng, 10.0);
        } else if (spec.arity === 2) {
          b = nextF64(rng);
        }
        const result = callFn(spec.name, a, b);
        const bHex = spec.arity === 2 ? hexBits(b) : "";
        out(`${label},${spec.name},${idx},${hexBits(a)},${bHex},${hexBits(result)}`);
      }
    }
  }

  out("impl,func,idx,a_hex,b_hex,result_hex");

  runBattery("js", (name, a, b) => JS_IMPL[name](a, b));

  try {
    const bytes = readBinary(WASM_PATH);
    const mod = new WebAssembly.Module(bytes);
    const instance = new WebAssembly.Instance(mod, {});
    const wasmExports = instance.exports;
    runBattery("wasm", (name, a, b) => wasmExports[name](a, b));
  } catch (e) {
    out(`# WASM leg failed: ${e && e.message ? e.message : e}`);
  }
})();
