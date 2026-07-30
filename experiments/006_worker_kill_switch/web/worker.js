// worker.js — runs one of the infinite-loop WASM binaries. wasi.start()
// below never returns for either variant; that's the point. The only way
// out is the main thread calling this Worker's own .terminate() from the
// outside — this file cannot exit itself and never tries to.
import { WASI, File, OpenFile, ConsoleStdout } from "./vendor/browser_wasi_shim/index.js";

self.onmessage = async (e) => {
  if (e.data?.type !== "run") return;
  const { variant, sab } = e.data;
  const heartbeat = new Int32Array(sab);

  const wasi = new WASI(
    [`loop_${variant}`],
    [],
    [
      new OpenFile(new File([])),
      ConsoleStdout.lineBuffered((msg) => self.postMessage({ type: "stdout", line: msg })),
      ConsoleStdout.lineBuffered((msg) => self.postMessage({ type: "stderr", line: msg })),
    ],
  );

  const resp = await fetch(new URL(`./loop_${variant}.wasm`, import.meta.url));
  const bytes = await resp.arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env: {
      heartbeat_tick: () => {
        Atomics.add(heartbeat, 0, 1);
      },
    },
  });

  self.postMessage({ type: "started" });
  // Never returns. Deliberately.
  wasi.start(instance);
};
