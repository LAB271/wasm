// measure.mjs — one cold-start measurement of index.html via Playwright.
// Playwright automates the *measurement* only; the page itself needs no
// automation to work in an ordinary tab (confirmed: it renders and runs
// correctly when opened via a plain static server — see README for the
// file:// vs. static-server finding).
import { chromium } from "playwright";

const baseUrl = process.argv[2] || "http://127.0.0.1:8899";

const browser = await chromium.launch();
const page = await browser.newPage();
const consoleErrors = [];
page.on("pageerror", (e) => consoleErrors.push(String(e.message)));

await page.goto(`${baseUrl}/index.html`, { waitUntil: "commit" });
await page.waitForSelector('[data-exp004-done="true"]', { timeout: 10000 });
const result = await page.evaluate(() => window.__exp004);
const text = await page.textContent("#out");

await browser.close();

if (consoleErrors.length || result.error || text.trim() !== "Hello World") {
  console.error(JSON.stringify({ ok: false, result, text, consoleErrors }));
  process.exit(1);
}

console.log(JSON.stringify({ ok: true, coldStartMs: result.coldStartMs }));
