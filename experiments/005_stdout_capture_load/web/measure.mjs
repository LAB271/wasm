// measure.mjs — one run at a given N and dom flag.
// Usage: node measure.mjs <baseUrl> <n> <dom: 0|1> [timeoutMs]
import { chromium } from "playwright";

const baseUrl = process.argv[2] || "http://127.0.0.1:8899";
const n = process.argv[3] || "10";
const dom = process.argv[4] || "1";
const timeoutMs = parseInt(process.argv[5] || "30000", 10);

const browser = await chromium.launch();
const page = await browser.newPage();
const consoleErrors = [];
page.on("pageerror", (e) => consoleErrors.push(String(e.message)));

let timedOut = false;
try {
  await page.goto(`${baseUrl}/index.html?n=${n}&dom=${dom}`, { waitUntil: "commit" });
  await page.waitForSelector('[data-exp005-done="true"]', { timeout: timeoutMs });
} catch (e) {
  timedOut = true;
}

const result = timedOut ? null : await page.evaluate(() => window.__exp005);
await browser.close();

if (timedOut) {
  console.log(JSON.stringify({ ok: false, timedOut: true, n: Number(n), dom }));
  process.exit(0); // a timeout is itself a valid, reportable measurement outcome
}

const expectedCount = Number(n);
const correctness =
  result.stdoutCount === expectedCount &&
  result.stderrCount === expectedCount &&
  result.stdoutCheck.ok &&
  result.stderrCheck.ok &&
  !result.error &&
  consoleErrors.length === 0;

console.log(JSON.stringify({
  ok: correctness,
  n: expectedCount,
  dom: Number(dom),
  stdoutCount: result.stdoutCount,
  stderrCount: result.stderrCount,
  stdoutCheck: result.stdoutCheck,
  stderrCheck: result.stderrCheck,
  workerElapsedMs: result.workerElapsedMs,
  mainThreadElapsedMs: result.lastMsgMs - result.mainThreadStartMs,
  consoleErrors,
}));
