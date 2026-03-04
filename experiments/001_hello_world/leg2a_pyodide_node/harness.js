"use strict";

const http = require("http");
const { loadPyodide } = require("pyodide");

const PORT = 5002;

async function main() {
  console.log("→ Loading Pyodide...");
  const pyodide = await loadPyodide();

  // Define the Python handler inside Pyodide
  await pyodide.runPythonAsync(`
import time
import json

def handle(request_path):
    return json.dumps({"message": "Hello World", "timestamp": time.time()})
`);

  const handleFn = pyodide.globals.get("handle");

  const server = http.createServer((req, res) => {
    try {
      const body = handleFn(req.url);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(body);
    } catch (err) {
      res.writeHead(500);
      res.end(String(err));
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
