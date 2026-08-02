// tests/perf.mjs — runs browser/index.html in real headless Chrome (system
// install via Playwright's `channel: 'chrome'`, no Playwright-managed
// Chromium download), same pattern as experiment 010's tests/browser.test.mjs.
// Confirms the Node CLI result (js/bench_010_rematch.mjs) holds in-browser.
import { chromium } from "playwright";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const PORT = process.argv[2] ?? "8020";
const BASE_URL = `http://127.0.0.1:${PORT}`;

function waitForHttp(url, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  return (async function poll() {
    while (Date.now() < deadline) {
      try {
        const res = await fetch(url);
        if (res.ok) return;
      } catch {
        // server not up yet
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error(`${url} did not respond within ${timeoutMs}ms`);
  })();
}

async function main() {
  const server = spawn("python3", ["serve.py", PORT], { cwd: root, stdio: "pipe" });
  server.on("error", (err) => { throw err; });

  try {
    await waitForHttp(`${BASE_URL}/browser/index.html`);
    const browser = await chromium.launch({ channel: "chrome", headless: true });
    try {
      const page = await browser.newPage();
      // Chrome logs a generic "Failed to load resource: ... 404" console error
      // for the browser-chrome-default favicon.ico request, with no URL in
      // the message text to filter on precisely — this page fetches nothing
      // else that could 404, so any "404" console error here is that, not a
      // real problem.
      const consoleErrors = [];
      page.on("console", (msg) => {
        if (msg.type() === "error" && !msg.text().includes("404")) consoleErrors.push(msg.text());
      });
      page.on("pageerror", (err) => consoleErrors.push(String(err)));

      await page.goto(`${BASE_URL}/browser/index.html`);
      await page.waitForSelector("#results.done, #results.error", { timeout: 20000 });

      const cls = await page.locator("#results").getAttribute("class");
      const text = await page.locator("#results").textContent();
      if (cls === "error") throw new Error(`browser leg reported an error: ${text}`);

      const results = JSON.parse(text);
      console.log(`chrome (headless), ${results.pairs.toLocaleString()} pairs/round:`);
      console.log(`  js tuned switch : ${results.js_tuned_switch.med.toFixed(4)} ms`);
      console.log(`  js bit-packed   : ${results.js_bitpacked.med.toFixed(4)} ms`);
      console.log(`  wasm            : ${results.wasm.med.toFixed(4)} ms`);
      console.log(`  ratio wasm vs tuned switch : ${results.ratio_wasm_vs_tuned_switch.toFixed(3)}x`);
      console.log(`  ratio wasm vs bit-packed   : ${results.ratio_wasm_vs_bitpacked.toFixed(3)}x`);

      if (consoleErrors.length > 0) throw new Error(`console errors: ${consoleErrors.join(" | ")}`);
    } finally {
      await browser.close();
    }
  } finally {
    server.kill();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
