// tests/browser.test.mjs — real headless Chrome, for both engines. Launches
// the system-installed Chrome via Playwright's `channel: 'chrome'` (no
// Playwright-managed Chromium download needed). Run after `make build`.
import { chromium } from "playwright";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const PORT = process.argv[2] ?? "8010";
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

async function testEngine(browser, engine) {
  const consoleErrors = [];
  const page = await browser.newPage();
  page.on("console", (msg) => {
    if (msg.type() === "error") consoleErrors.push(msg.text());
  });
  page.on("pageerror", (err) => consoleErrors.push(String(err)));

  await page.goto(`${BASE_URL}/?engine=${engine}`);
  await page.waitForSelector("#engine-status.ready", { timeout: 5000 });

  const statusText = await page.locator("#engine-status").textContent();
  if (!statusText.includes(engine)) {
    throw new Error(`[${engine}] engine-status did not report the expected engine: "${statusText}"`);
  }

  for (let i = 0; i < 4; i++) {
    await page.locator("#palette button").first().click();
  }
  await page.locator("#submit-btn").click();

  const rowCount = await page.locator("#board .row").count();
  if (rowCount !== 1) throw new Error(`[${engine}] expected 1 board row after submit, got ${rowCount}`);

  const dotCount = await page.locator("#board .row .feedback .dot").count();
  if (dotCount !== 4) throw new Error(`[${engine}] expected 4 feedback dots, got ${dotCount}`);

  const attemptText = await page.locator("#attempt-count").textContent();
  if (attemptText !== "1") throw new Error(`[${engine}] expected attempt-count "1", got "${attemptText}"`);

  await page.close();

  if (consoleErrors.length > 0) {
    throw new Error(`[${engine}] console errors: ${consoleErrors.join(" | ")}`);
  }

  console.log(`ok  [${engine}] engine loaded, guess submitted, feedback rendered, no console errors`);
}

async function main() {
  const server = spawn("python3", ["serve.py", PORT], { cwd: root, stdio: "pipe" });
  server.on("error", (err) => {
    throw err;
  });

  try {
    await waitForHttp(`${BASE_URL}/index.html`);

    const browser = await chromium.launch({ channel: "chrome", headless: true });
    try {
      for (const engine of ["rust", "as"]) {
        await testEngine(browser, engine);
      }
    } finally {
      await browser.close();
    }

    console.log("\nall browser tests passed");
  } finally {
    server.kill();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
