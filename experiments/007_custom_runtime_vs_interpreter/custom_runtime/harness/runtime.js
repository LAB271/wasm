// runtime.js — the entire hand-written "language runtime" this leg tests
// the cost of. Mirrors mvl-lang/mvl-playground's actual pattern in
// web/src/runtime/mvl-runtime.ts: a Map-based handle table, string bytes
// read directly out of the WASM instance's own linear memory.
export function createRuntime(getMemory) {
  const strings = new Map();
  let nextHandle = 1;
  const decoder = new TextDecoder("utf-8");
  const encoder = new TextEncoder();

  function readString(ptr, len) {
    const bytes = new Uint8Array(getMemory().buffer, ptr, len);
    return decoder.decode(bytes);
  }

  return {
    imports: {
      string_new: (ptr, len) => {
        const h = nextHandle++;
        strings.set(h, readString(ptr, len));
        return h;
      },
      string_concat: (h1, h2) => {
        const h = nextHandle++;
        strings.set(h, (strings.get(h1) ?? "") + (strings.get(h2) ?? ""));
        return h;
      },
      string_write: (handle, destPtr) => {
        const s = strings.get(handle) ?? "";
        const bytes = encoder.encode(s);
        new Uint8Array(getMemory().buffer, destPtr, bytes.length).set(bytes);
        return bytes.length;
      },
    },
    handleCount: () => strings.size,
  };
}
