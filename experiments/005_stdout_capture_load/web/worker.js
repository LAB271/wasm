// worker.js — runs line_flood.wasm, printing N interleaved stdout/stderr
// lines. One postMessage per captured line (deliberately not batched —
// the point is to measure per-message overhead, not hide it).
import { WASI, File, OpenFile, ConsoleStdout } from "./vendor/browser_wasi_shim/index.js";

self.onmessage = async (e) => {
  if (e.data?.type !== "run") return;
  const n = e.data.n;

  const wasi = new WASI(
    ["line_flood", String(n)],
    [],
    [
      new OpenFile(new File([])),
      ConsoleStdout.lineBuffered((msg) => self.postMessage({ type: "stdout", line: msg })),
      ConsoleStdout.lineBuffered((msg) => self.postMessage({ type: "stderr", line: msg })),
    ],
  );

  try {
    const resp = await fetch(new URL("./line_flood.wasm", import.meta.url));
    const bytes = await resp.arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, {
      wasi_snapshot_preview1: wasi.wasiImport,
    });

    // Worker-side elapsed time: WASM execution + N synchronous postMessage
    // dispatch calls (structured-clone serialization), NOT main-thread
    // message handling or DOM work, which happens after this returns.
    const workerStart = performance.now();
    const exitCode = wasi.start(instance);
    const workerElapsedMs = performance.now() - workerStart;

    self.postMessage({ type: "done", exitCode, workerElapsedMs });
  } catch (err) {
    self.postMessage({ type: "error", message: String(err && err.message || err) });
  }
};
