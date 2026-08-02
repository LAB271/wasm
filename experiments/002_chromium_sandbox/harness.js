"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");
const { Pool } = require("pg");

// ── Configuration ────────────────────────────────────────────────────────────
const PYODIDE_CDN = "https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js";

const LEG_CONFIG = {
  "1a": { port: 5010, workload: "cpu_bound",      isolation: "shared",  concurrency: "sequential" },
  "1b": { port: 5011, workload: "cpu_bound",      isolation: "shared",  concurrency: "workers" },
  "2a": { port: 5012, workload: "json_transform",  isolation: "shared",  concurrency: "sequential" },
  "2b": { port: 5013, workload: "json_transform",  isolation: "fresh",   concurrency: "sequential" },
  "3a": { port: 5014, workload: "db_query",        isolation: "shared",  concurrency: "sequential", db: true },
  "3b": { port: 5015, workload: "db_query",        isolation: "fresh",   concurrency: "sequential", db: true },
  "4a": { port: 5016, workload: "mixed",           isolation: "shared",  concurrency: "sequential", db: true },
  "4b": { port: 5017, workload: "mixed",           isolation: "pool",    concurrency: "concurrent", db: true },
  // Legs 5a/5b: native-compiled WASM run directly in V8 — no Pyodide, no Python
  // interpreter. Same fib(30)+matrix(20) computation as cpu_bound.py, to show
  // whether Pyodide's cold-start/memory overhead is Pyodide-specific or
  // inherent to running WASM inside a browser. Shared page + sequential,
  // identical isolation to leg 1a, for an apples-to-apples comparison.
  "5a": { port: 5018, runtime: "wasm", wasmEngine: "rust",           isolation: "shared", concurrency: "sequential" },
  "5b": { port: 5019, runtime: "wasm", wasmEngine: "assemblyscript", isolation: "shared", concurrency: "sequential" },
};

const POOL_SIZE = 5;

// ── Parse CLI args ──────────────────────────────────────────────────────────
const legArg = process.argv[2];
if (!legArg || !LEG_CONFIG[legArg]) {
  console.error(`Usage: node harness.js <leg>\nLegs: ${Object.keys(LEG_CONFIG).join(", ")}`);
  process.exit(1);
}

const config = LEG_CONFIG[legArg];
const PORT = config.port;

// ── Load workload Python source (Pyodide legs only) ─────────────────────────
const workloadSource = config.workload
  ? fs.readFileSync(path.join(__dirname, "workloads", `${config.workload}.py`), "utf-8")
  : null;

// ── Load native WASM binary, base64-encoded for page.evaluate (legs 5a/5b) ──
const WASM_PATHS = {
  rust: path.join(__dirname, "workloads", "rust", "pkg", "cpu_bound_bg.wasm"),
  assemblyscript: path.join(__dirname, "workloads", "assemblyscript", "build", "cpu_bound.wasm"),
};
const wasmBytesB64 = config.runtime === "wasm"
  ? fs.readFileSync(WASM_PATHS[config.wasmEngine]).toString("base64")
  : null;

// ── Postgres pool (for DB legs) ─────────────────────────────────────────────
let pgPool = null;
if (config.db) {
  pgPool = new Pool({
    host: "127.0.0.1", port: 5432,
    database: "bench", user: "bench", password: "bench",
    max: 10,
  });
}

// ── Helper: initialize Pyodide on a page ────────────────────────────────────
async function initPyodidePage(browser) {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("about:blank");
  await page.addScriptTag({ url: PYODIDE_CDN });
  await page.evaluate(async (src) => {
    window.pyodide = await loadPyodide();
    await window.pyodide.runPythonAsync(src);
  }, workloadSource);
  return { context, page };
}

// ── Helper: run workload on a page ──────────────────────────────────────────
async function runOnPage(page, requestUrl, dbRow) {
  const t0 = process.hrtime.bigint();

  let body;
  if (dbRow !== undefined) {
    body = await page.evaluate(({ url, row }) => {
      const pyRow = row ? window.pyodide.toPy(row) : null;
      const result = window.pyodide.globals.get("handle")(url, pyRow);
      if (pyRow) pyRow.destroy();
      return result;
    }, { url: requestUrl, row: dbRow });
  } else {
    body = await page.evaluate((url) => {
      return window.pyodide.globals.get("handle")(url);
    }, requestUrl);
  }

  const bridgeMs = Number(process.hrtime.bigint() - t0) / 1_000_000;
  return { body, bridgeMs };
}

// ── Helper: fetch DB row via host bridge ────────────────────────────────────
async function fetchDbRow(url) {
  const match = url.match(/[?&]id=(\d+)/);
  const itemId = match ? parseInt(match[1], 10) : 1;
  const t0 = process.hrtime.bigint();
  const result = await pgPool.query(
    "SELECT id, name, value FROM items WHERE id = $1", [itemId]
  );
  const queryMs = Number(process.hrtime.bigint() - t0) / 1_000_000;
  const row = result.rows[0];
  if (!row) return null;
  return [row.id, row.name, row.value, Math.round(queryMs * 1000) / 1000];
}

// ── Strategies ──────────────────────────────────────────────────────────────

// Shared page: single page for all requests
async function startShared(browser) {
  const { page } = await initPyodidePage(browser);

  return async (req, res) => {
    try {
      const dbRow = config.db ? await fetchDbRow(req.url) : undefined;
      const { body, bridgeMs } = await runOnPage(page, req.url, dbRow);

      // Inject bridge overhead into response
      const parsed = JSON.parse(body);
      parsed._bridge_ms = Math.round(bridgeMs * 100) / 100;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(parsed));
    } catch (err) {
      res.writeHead(500);
      res.end(JSON.stringify({ error: String(err) }));
    }
  };
}

// Fresh BrowserContext per request
async function startFresh(browser) {
  return async (req, res) => {
    const ctxStart = process.hrtime.bigint();
    let context, page;
    try {
      ({ context, page } = await initPyodidePage(browser));
      const ctxMs = Number(process.hrtime.bigint() - ctxStart) / 1_000_000;

      const dbRow = config.db ? await fetchDbRow(req.url) : undefined;
      const { body, bridgeMs } = await runOnPage(page, req.url, dbRow);

      const parsed = JSON.parse(body);
      parsed._bridge_ms = Math.round(bridgeMs * 100) / 100;
      parsed._context_create_ms = Math.round(ctxMs * 100) / 100;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(parsed));
    } catch (err) {
      res.writeHead(500);
      res.end(JSON.stringify({ error: String(err) }));
    } finally {
      if (context) await context.close().catch(() => {});
    }
  };
}

// BrowserContext pool (N contexts, round-robin)
async function startPool(browser) {
  const pool = [];
  for (let i = 0; i < POOL_SIZE; i++) {
    pool.push(await initPyodidePage(browser));
  }
  let robin = 0;

  return async (req, res) => {
    const idx = robin;
    robin = (robin + 1) % POOL_SIZE;
    const { page } = pool[idx];

    try {
      const dbRow = config.db ? await fetchDbRow(req.url) : undefined;
      const { body, bridgeMs } = await runOnPage(page, req.url, dbRow);

      const parsed = JSON.parse(body);
      parsed._bridge_ms = Math.round(bridgeMs * 100) / 100;
      parsed._pool_index = idx;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(parsed));
    } catch (err) {
      res.writeHead(500);
      res.end(JSON.stringify({ error: String(err) }));
    }
  };
}

// Web Worker pool (Leg 1b): use multiple pages as "workers"
async function startWorkers(browser) {
  const workers = [];
  for (let i = 0; i < POOL_SIZE; i++) {
    workers.push(await initPyodidePage(browser));
  }
  let robin = 0;

  return async (req, res) => {
    const idx = robin;
    robin = (robin + 1) % POOL_SIZE;
    const { page } = workers[idx];

    try {
      const { body, bridgeMs } = await runOnPage(page, req.url);
      const parsed = JSON.parse(body);
      parsed._bridge_ms = Math.round(bridgeMs * 100) / 100;
      parsed._worker_index = idx;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(parsed));
    } catch (err) {
      res.writeHead(500);
      res.end(JSON.stringify({ error: String(err) }));
    }
  };
}

// Native WASM in V8 — no Pyodide (Legs 5a/5b)
async function initWasmPage(browser, engine, b64) {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("about:blank");
  await page.evaluate(({ b64, engine }) => {
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    return WebAssembly.instantiate(
      bytes,
      engine === "assemblyscript" ? { env: { abort() { throw new Error("assemblyscript abort"); } } } : {}
    ).then(({ instance }) => {
      const wasm = instance.exports;
      if (engine === "rust") {
        // Mirrors wasm-pack's `--target web` glue (workloads/rust/pkg/cpu_bound.js):
        // handle() returns a (ptr, len) pair via an out-param on the shadow stack.
        const decoder = new TextDecoder("utf-8");
        window.__wasmHandle = () => {
          const retptr = wasm.__wbindgen_add_to_stack_pointer(-16);
          wasm.handle(retptr);
          const dv = new DataView(wasm.memory.buffer);
          const ptr = dv.getInt32(retptr + 0, true);
          const len = dv.getInt32(retptr + 4, true);
          const str = decoder.decode(new Uint8Array(wasm.memory.buffer, ptr, len));
          wasm.__wbindgen_add_to_stack_pointer(16);
          wasm.__wbindgen_export(ptr, len, 1);
          return str;
        };
      } else {
        // AssemblyScript string layout: a 4-byte UTF-16LE length prefix
        // immediately precedes the data the returned pointer points to.
        const decoder = new TextDecoder("utf-16le");
        window.__wasmHandle = () => {
          const ptr = wasm.handle();
          const len = new DataView(wasm.memory.buffer).getUint32(ptr - 4, true);
          return decoder.decode(new Uint8Array(wasm.memory.buffer, ptr, len));
        };
      }
    });
  }, { b64, engine });
  return { context, page };
}

async function runWasmOnPage(page) {
  const t0 = process.hrtime.bigint();
  const body = await page.evaluate(() => window.__wasmHandle());
  const bridgeMs = Number(process.hrtime.bigint() - t0) / 1_000_000;
  return { body, bridgeMs };
}

// Shared page, native WASM, sequential (legs 5a/5b) — mirrors startShared()
async function startSharedWasm(browser) {
  const { page } = await initWasmPage(browser, config.wasmEngine, wasmBytesB64);

  return async (req, res) => {
    try {
      const { body, bridgeMs } = await runWasmOnPage(page);
      const parsed = JSON.parse(body);
      parsed._bridge_ms = Math.round(bridgeMs * 100) / 100;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(parsed));
    } catch (err) {
      res.writeHead(500);
      res.end(JSON.stringify({ error: String(err) }));
    }
  };
}

// ── Main ────────────────────────────────────────────────────────────────────
async function main() {
  console.log(`→ Leg ${legArg}: ${config.workload || config.wasmEngine} / ${config.isolation} / ${config.concurrency}`);
  console.log("→ Launching headless Chrome (Playwright)...");

  const browser = await chromium.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-gpu"],
  });

  if (config.db) {
    await pgPool.query("SELECT 1");
    console.log("→ Postgres connected");
  }

  let handler;
  if (config.runtime === "wasm") {
    handler = await startSharedWasm(browser);
  } else {
    switch (config.isolation) {
      case "shared":
        handler = config.concurrency === "workers"
          ? await startWorkers(browser)
          : await startShared(browser);
        break;
      case "fresh":
        handler = await startFresh(browser);
        break;
      case "pool":
        handler = await startPool(browser);
        break;
      default:
        throw new Error(`Unknown isolation: ${config.isolation}`);
    }
  }

  console.log(config.runtime === "wasm" ? "→ WASM instance ready inside Chrome" : "→ Pyodide ready inside Chrome");

  const server = http.createServer(handler);
  server.listen(PORT, "127.0.0.1", () => {
    console.log(`→ Listening on http://127.0.0.1:${PORT}/`);
  });

  const shutdown = async () => {
    server.close();
    if (pgPool) await pgPool.end().catch(() => {});
    await browser.close();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err) => {
  console.error("✗ Failed to start:", err);
  process.exit(1);
});
