// worker.js — runs the compiled WASM binary client-side, in a Web Worker.
// Mirrors mvl-lang/mvl-playground's web/src/runtime/worker.ts pattern:
// a Worker instantiates the module against @bjorn3/browser_wasi_shim and
// posts stdout/stderr lines back to the main thread as they're produced.
//
// No server is involved here at all — this file only ever fetches a
// same-origin static asset (the pre-built .wasm) and a vendored copy of
// the shim, both produced ahead of time by build.sh.

import { WASI, File, OpenFile, ConsoleStdout } from "./vendor/browser_wasi_shim/index.js";

self.onmessage = async (e) => {
  if (e.data?.type !== "run") return;

  const wasi = new WASI(
    [], // argv
    [], // envp
    [
      new OpenFile(new File([])), // stdin, unused
      ConsoleStdout.lineBuffered((msg) => self.postMessage({ type: "stdout", line: msg })),
      ConsoleStdout.lineBuffered((msg) => self.postMessage({ type: "stderr", line: msg })),
    ],
  );

  try {
    const resp = await fetch(new URL("./hello_wasi.wasm", import.meta.url));
    const bytes = await resp.arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, {
      wasi_snapshot_preview1: wasi.wasiImport,
    });
    // wasi.start() catches the shim's internal WASIProcExit itself and
    // *returns* the exit code — it does not rethrow it for a clean exit
    // (verified by reading dist/wasi.js: `catch(e){ if (e instanceof
    // WASIProcExit) return e.code; else throw e }`). Anything that
    // reaches our own catch block below is a genuine trap, not a normal
    // program exit.
    const exitCode = wasi.start(instance);
    self.postMessage({ type: "done", exitCode });
  } catch (err) {
    self.postMessage({ type: "error", message: String(err && err.message || err) });
  }
};
