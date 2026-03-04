"use strict";

const http = require("http");
const puppeteer = require("puppeteer");

const PORT = 5008;
const PYODIDE_CDN = "https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js";

async function main() {
  console.log("→ Launching headless Chrome...");
  const browser = await puppeteer.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-gpu"],
  });

  const page = await browser.newPage();
  await page.goto("about:blank");

  console.log("→ Loading Pyodide inside Chrome...");
  await page.addScriptTag({ url: PYODIDE_CDN });
  await page.evaluate(async () => {
    window.pyodide = await loadPyodide();
    await window.pyodide.runPythonAsync(`
import time
import json

def handle(request_path):
    return json.dumps({"message": "Hello World", "timestamp": time.time()})
`);
  });

  console.log("→ Pyodide ready inside Chrome");

  const server = http.createServer(async (req, res) => {
    try {
      const body = await page.evaluate((url) => {
        return window.pyodide.globals.get("handle")(url);
      }, req.url);
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

  process.on("SIGTERM", async () => {
    server.close();
    await browser.close();
    process.exit(0);
  });
  process.on("SIGINT", async () => {
    server.close();
    await browser.close();
    process.exit(0);
  });
}

main().catch((err) => {
  console.error("✗ Failed to start:", err);
  process.exit(1);
});
