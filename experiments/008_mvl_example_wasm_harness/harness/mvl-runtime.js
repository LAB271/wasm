// mvl-runtime.js — standalone JS implementation of the MVL WASM runtime.
//
// Ported verbatim (mechanical TS -> JS translation, no logic changes) from
// mvl-lang/mvl-playground's web/src/runtime/mvl-runtime.ts, so this harness
// tests the actual runtime the playground ships, not a reimplementation of
// it. If mvl-runtime.ts changes, port the change here too — divergence
// between this file and the playground's is exactly the kind of drift this
// whole session has been about catching.
//
// The MVL WASM backend (mvl build --backend=wasm) emits imports under a
// "runtime" namespace: a shared WebAssembly.Memory plus ~60 functions for
// string/array/option/result/map operations. The WASM module uses a bump
// allocator within this memory, writes string bytes, and passes (ptr, len)
// pairs to runtime functions. Functions that "create" values (string_new,
// array_new, option_some, etc.) return opaque i32 handles into
// runtime-managed tables.
//
// Source: mvl-lang/mvl-playground web/src/runtime/mvl-runtime.ts,
// mvl-lang/mvl release v1.7.2 runtime.

let nextHandle = 1;

function newHandle() {
  return nextHandle++;
}

export function createMvlRuntime() {
  const memory = new WebAssembly.Memory({ initial: 1, maximum: 256 });
  const u8 = () => new Uint8Array(memory.buffer);

  const strings = new Map();
  const arrays = new Map();
  const options = new Map();
  const results = new Map();
  const maps = new Map();
  const structs = new Map();

  const decoder = new TextDecoder("utf-8");

  function readString(ptr, len) {
    if (len <= 0) return "";
    return decoder.decode(u8().subarray(ptr, ptr + len));
  }

  function storeString(s) {
    const h = newHandle();
    strings.set(h, s);
    return h;
  }

  function storeArray(a) {
    const h = newHandle();
    arrays.set(h, a);
    return h;
  }

  function storeOption(tag, value) {
    const h = newHandle();
    options.set(h, { tag, value });
    return h;
  }

  function storeResult(tag, value, error) {
    const h = newHandle();
    results.set(h, { tag, value, error });
    return h;
  }

  function storeMap(m) {
    const h = newHandle();
    maps.set(h, m);
    return h;
  }

  const runtime = {
    memory,

    // ── String functions (ptr, len) -> handle or scalar ──────────────

    _mvl_string_eq: (p1, l1, p2, l2) =>
      readString(p1, l1) === readString(p2, l2) ? 1 : 0,

    _mvl_string_len: (ptr, len) => BigInt([...readString(ptr, len)].length),

    _mvl_string_is_empty: (ptr, len) => (readString(ptr, len).length === 0 ? 1 : 0),

    _mvl_string_contains: (p1, l1, p2, l2) =>
      readString(p1, l1).includes(readString(p2, l2)) ? 1 : 0,

    _mvl_string_starts_with: (p1, l1, p2, l2) =>
      readString(p1, l1).startsWith(readString(p2, l2)) ? 1 : 0,

    _mvl_string_ends_with: (p1, l1, p2, l2) =>
      readString(p1, l1).endsWith(readString(p2, l2)) ? 1 : 0,

    _mvl_string_find: (p1, l1, p2, l2) => {
      const idx = readString(p1, l1).indexOf(readString(p2, l2));
      return BigInt(idx);
    },

    _mvl_string_new: (ptr, len) => storeString(readString(ptr, len)),

    _mvl_string_clone: (h) => {
      const s = strings.get(h);
      return s !== undefined ? storeString(s) : storeString("");
    },

    _mvl_string_drop: (h) => {
      strings.delete(h);
    },

    _mvl_string_concat: (p1, l1, p2, l2) =>
      storeString(readString(p1, l1) + readString(p2, l2)),

    _mvl_string_substring: (ptr, len, start, end) => {
      const s = readString(ptr, len);
      const chars = [...s];
      const lo = Math.max(0, Number(start));
      const hi = Math.max(0, Number(end));
      return storeString(chars.slice(lo, Math.min(hi, chars.length)).join(""));
    },

    _mvl_string_to_upper: (ptr, len) => storeString(readString(ptr, len).toUpperCase()),

    _mvl_string_to_lower: (ptr, len) => storeString(readString(ptr, len).toLowerCase()),

    _mvl_string_trim: (ptr, len) => storeString(readString(ptr, len).trim()),

    _mvl_string_replace: (sp, sl, fp, fl, tp, tl) =>
      storeString(readString(sp, sl).split(readString(fp, fl)).join(readString(tp, tl))),

    _mvl_string_parse_int: (ptr, len) => {
      const s = readString(ptr, len).trim();
      const n = Number(s);
      if (s !== "" && !isNaN(n) && Number.isInteger(n)) {
        return storeResult(1, BigInt(n));
      }
      return storeResult(0, 0n, `invalid integer: "${s}"`);
    },

    // ── Array functions (handle-based) ────────────────────────────────

    _mvl_array_new: (_elemType, _capacity) => storeArray([]),

    _mvl_array_len: (h) => BigInt(arrays.get(h)?.length ?? 0),

    _mvl_array_is_empty: (h) => ((arrays.get(h)?.length ?? 1) === 0 ? 1 : 0),

    _mvl_array_push: (h, val) => {
      arrays.get(h)?.push(val);
    },

    _mvl_array_push_i32: (h, val) => {
      arrays.get(h)?.push(val);
    },

    _mvl_array_push_i64: (h, val) => {
      arrays.get(h)?.push(val);
    },

    _mvl_array_push_f64: (h, val) => {
      arrays.get(h)?.push(val);
    },

    _mvl_array_get: (h, idx) => {
      const arr = arrays.get(h);
      if (!arr) return 0;
      const i = Number(idx);
      return i >= 0 && i < arr.length ? arr[i] : 0;
    },

    _mvl_array_clone: (h) => {
      const arr = arrays.get(h);
      return storeArray(arr ? [...arr] : []);
    },

    _mvl_array_drop: (h) => {
      arrays.delete(h);
    },

    _mvl_string_ptr_array_drop: (h) => {
      arrays.delete(h);
    },

    _mvl_string_ptr_array_dedup: (h) => {
      const arr = arrays.get(h);
      if (arr) {
        const seen = new Set();
        const deduped = arr.filter((v) => {
          if (seen.has(v)) return false;
          seen.add(v);
          return true;
        });
        arrays.set(h, deduped);
      }
    },

    _mvl_array_dedup_i64: (h) => {
      const arr = arrays.get(h);
      if (arr) {
        const seen = new Set();
        arrays.set(h, arr.filter((v) => (seen.has(v) ? false : (seen.add(v), true))));
      }
    },

    _mvl_array_dedup_i32: (h) => {
      const arr = arrays.get(h);
      if (arr) {
        const seen = new Set();
        arrays.set(h, arr.filter((v) => (seen.has(v) ? false : (seen.add(v), true))));
      }
    },

    _mvl_array_contains_i64: (h, val) => {
      const arr = arrays.get(h);
      return arr && arr.includes(val) ? 1 : 0;
    },

    _mvl_array_contains_i32: (h, val) => {
      const arr = arrays.get(h);
      return arr && arr.includes(val) ? 1 : 0;
    },

    _mvl_array_insert_i64: (h, val) => {
      arrays.get(h)?.push(val);
    },

    _mvl_array_insert_i32: (h, val) => {
      arrays.get(h)?.push(val);
    },

    // ── Option functions ─────────────────────────────────────────────

    _mvl_option_some_i64: (val) => storeOption(1, val),
    _mvl_option_some_i32: (val) => storeOption(1, val),
    _mvl_option_none: () => storeOption(0, 0),

    _mvl_option_tag: (h) => options.get(h)?.tag ?? 0,

    _mvl_option_value_i64: (h) => {
      const opt = options.get(h);
      return opt ? BigInt(opt.value) : 0n;
    },

    _mvl_option_value_i32: (h) => {
      const opt = options.get(h);
      return opt ? Number(opt.value) : 0;
    },

    _mvl_option_drop: (h) => {
      options.delete(h);
    },

    _mvl_array_get_option_i64: (h, idx) => {
      const arr = arrays.get(h);
      if (!arr) return storeOption(0, 0);
      const i = Number(idx);
      if (i < 0 || i >= arr.length) return storeOption(0, 0);
      return storeOption(1, BigInt(arr[i]));
    },

    _mvl_array_get_option_i32: (h, idx) => {
      const arr = arrays.get(h);
      if (!arr) return storeOption(0, 0);
      const i = Number(idx);
      if (i < 0 || i >= arr.length) return storeOption(0, 0);
      return storeOption(1, arr[i]);
    },

    // ── Result functions ──────────────────────────────────────────────

    _mvl_result_ok_i64: (val) => storeResult(1, val),
    _mvl_result_ok_i32: (val) => storeResult(1, val),
    _mvl_result_err_str: (ptr, len) => storeResult(0, 0, readString(ptr, len)),

    _mvl_result_tag: (h) => results.get(h)?.tag ?? 0,

    _mvl_result_value_i64: (h) => {
      const r = results.get(h);
      return r ? BigInt(r.value) : 0n;
    },

    _mvl_result_value_i32: (h) => {
      const r = results.get(h);
      return r ? Number(r.value) : 0;
    },

    _mvl_result_drop: (h) => {
      results.delete(h);
    },

    // ── Map functions ─────────────────────────────────────────────────

    _mvl_map_new_si64: () => storeMap(new Map()),

    _mvl_map_len: (h) => BigInt(maps.get(h)?.size ?? 0),

    _mvl_map_insert_si64: (h, kp, kl, val) => {
      maps.get(h)?.set(readString(kp, kl), val);
    },

    _mvl_map_get_si64: (h, kp, kl) => {
      const m = maps.get(h);
      if (!m) return storeOption(0, 0);
      const val = m.get(readString(kp, kl));
      if (val === undefined) return storeOption(0, 0);
      return storeOption(1, BigInt(val));
    },

    _mvl_map_contains_key_si64: (h, kp, kl) =>
      maps.get(h)?.has(readString(kp, kl)) ? 1 : 0,

    _mvl_map_drop_si64: (h) => {
      maps.delete(h);
    },

    // ── Struct ─────────────────────────────────────────────────────────

    _mvl_struct_alloc: (size) => {
      const h = newHandle();
      structs.set(h, new Uint8Array(size));
      return h;
    },

    // ── Audit (no-op — this harness doesn't persist an audit trail) ───

    _mvl_audit_emit_relabel: (
      _tagPtr, _tagLen,
      _fromPtr, _fromLen,
      _toPtr, _toLen,
      _filePtr, _fileLen,
      _line, _col,
    ) => {
      // No-op, matching mvl-playground's own runtime.
    },
  };

  return { memory, runtime };
}
