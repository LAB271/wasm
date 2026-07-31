// Minimal ambient shape for the ported MVL WASM runtime — see mvl-runtime.js
// (vendored from lab271/wasm experiment 008, fixed there for the struct/
// array/string memory bugs found while building this experiment).
export interface MvlRuntime {
  memory: WebAssembly.Memory;
  _mvl_array_new(elemType: number, capacity: number): number;
  _mvl_array_push_i64(handle: number, value: bigint): void;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  [key: string]: any;
}

export function createMvlRuntime(): { memory: WebAssembly.Memory; runtime: MvlRuntime };
