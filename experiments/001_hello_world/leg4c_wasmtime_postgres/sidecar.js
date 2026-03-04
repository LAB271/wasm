"use strict";

const http = require("http");
const { Pool } = require("pg");

const PORT = 5007;

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
  await pgPool.query("SELECT 1");
  console.log("→ Postgres connection verified");

  const server = http.createServer(async (req, res) => {
    try {
      if (!req.url.startsWith("/query")) {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end('{"error":"unknown endpoint"}');
        return;
      }

      const itemId = parseId(req.url);
      const t0 = process.hrtime.bigint();
      const result = await pgPool.query(
        "SELECT id, name, value FROM items WHERE id = $1",
        [itemId]
      );
      const queryMs = Number(process.hrtime.bigint() - t0) / 1_000_000;

      const row = result.rows[0];
      if (!row) {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end('{"error":"not found"}');
        return;
      }

      const body = JSON.stringify({
        id: row.id,
        name: row.name,
        value: row.value,
        query_ms: Math.round(queryMs * 1000) / 1000,
      });

      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(body);
    } catch (err) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: String(err) }));
    }
  });

  server.listen(PORT, "127.0.0.1", () => {
    console.log(`→ Sidecar listening on http://127.0.0.1:${PORT}/`);
  });
}

main().catch((err) => {
  console.error("✗ Failed to start sidecar:", err);
  process.exit(1);
});
