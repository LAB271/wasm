"use strict";

const http = require("http");
const { loadPyodide } = require("pyodide");
const { Pool } = require("pg");

const PORT = 5005;

const pgPool = new Pool({
  host: "127.0.0.1",
  port: 5432,
  database: "bench",
  user: "bench",
  password: "bench",
  max: 5,
});

function parseId(url) {
  const match = url.match(/[?&]id=(\d+)/);
  return match ? parseInt(match[1], 10) : 1;
}

async function main() {
  console.log("→ Loading Pyodide...");
  const pyodide = await loadPyodide();

  // Python handler: receives a pre-queried row from the host bridge.
  // This mirrors real WASM components where the host provides I/O capabilities
  // and the WASM module processes the result.
  await pyodide.runPythonAsync(`
import time
import json

def handle_hello(request_path):
    return json.dumps({"message": "Hello World", "timestamp": time.time()})

def handle_db(request_path, row):
    """Format a DB result received via the host bridge."""
    if row is None:
        return json.dumps({"error": "not found"})

    return json.dumps({
        "id": row[0],
        "name": row[1],
        "value": row[2],
        "query_ms": row[3],
        "timestamp": time.time(),
    })
`);

  const handleHelloFn = pyodide.globals.get("handle_hello");
  const handleDbFn = pyodide.globals.get("handle_db");

  // Verify Postgres is reachable
  await pgPool.query("SELECT 1");
  console.log("→ Postgres connection verified");

  const server = http.createServer(async (req, res) => {
    try {
      let body;

      if (req.url.startsWith("/db")) {
        // Host-side: perform the actual DB query (host-provided capability)
        const itemId = parseId(req.url);
        const t0 = process.hrtime.bigint();
        const result = await pgPool.query(
          "SELECT id, name, value FROM items WHERE id = $1",
          [itemId]
        );
        const queryMs =
          Number(process.hrtime.bigint() - t0) / 1_000_000;

        const row = result.rows[0];
        if (!row) {
          res.writeHead(404, { "Content-Type": "application/json" });
          res.end('{"error":"not found"}');
          return;
        }

        // Bridge: pass the query result into the WASM module (Pyodide)
        const pyRow = pyodide.toPy([
          row.id,
          row.name,
          row.value,
          Math.round(queryMs * 1000) / 1000,
        ]);
        body = handleDbFn(req.url, pyRow);
        pyRow.destroy();
      } else {
        body = handleHelloFn(req.url);
      }

      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(body);
    } catch (err) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: String(err) }));
    }
  });

  server.listen(PORT, "127.0.0.1", () => {
    console.log(`→ Listening on http://127.0.0.1:${PORT}/`);
  });
}

main().catch((err) => {
  console.error("✗ Failed to start:", err);
  process.exit(1);
});
