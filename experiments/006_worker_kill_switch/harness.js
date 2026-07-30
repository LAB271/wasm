// harness.js — for one variant (pure|alloc): starts the infinite loop,
// samples process-tree CPU while it runs, calls terminate(), then polls
// the SharedArrayBuffer heartbeat every 100ms until it stops changing.
//
// Two independent lines of evidence for "did it actually die":
//   1. Heartbeat freezes — direct proof the loop stopped executing. This
//      doesn't depend on cooperation from the (possibly dead) worker: the
//      main thread just reads shared memory, which exists independent of
//      whether the writer is still alive.
//   2. Process-tree CPU%% drops — external, OS-level corroboration.
//
// Usage: node harness.js <pure|alloc>
import { chromium } from "playwright";
import { execSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const variant = process.argv[2] === "alloc" ? "alloc" : "pure";
const baseUrl = process.argv[3] || "http://127.0.0.1:8899";
const warmupMs = variant === "alloc" ? 300 : 500; // shorter warmup for alloc: it grows memory fast
const POLL_MS = 100;
const POLL_BUDGET_MS = 6000; // generous; observed death is ~2.1s

function descendantPids(pid) {
  let all = [pid];
  let frontier = [pid];
  while (frontier.length) {
    const next = [];
    for (const p of frontier) {
      try {
        const out = execSync(`pgrep -P ${p}`, { encoding: "utf8" }).trim();
        if (out) next.push(...out.split("\n").map(Number));
      } catch { /* no children */ }
    }
    all.push(...next);
    frontier = next;
  }
  return all;
}

function totalCpuPct(pids) {
  if (!pids.length) return 0;
  try {
    const out = execSync(`ps -o pcpu= -p ${pids.join(",")}`, { encoding: "utf8" });
    return out.trim().split("\n").filter(Boolean).map(Number).reduce((a, b) => a + b, 0);
  } catch {
    return 0;
  }
}

const userDataDir = mkdtempSync(join(tmpdir(), "exp006-"));
const ctx = await chromium.launchPersistentContext(userDataDir, { headless: true });

// Find this context's own process tree via its unique --user-data-dir.
const psOut = execSync(`ps -ax -o pid,command`, { encoding: "utf8" });
const ownerLine = psOut.split("\n").find((l) => l.includes(userDataDir) && !l.includes("grep"));
const mainPid = Number(ownerLine.trim().split(/\s+/)[0]);

const page = ctx.pages()[0] ?? await ctx.newPage();

const cpuBaseline = totalCpuPct(descendantPids(mainPid));

await page.goto(`${baseUrl}/index.html?variant=${variant}`);
await page.waitForSelector('[data-exp006-started="true"]', { timeout: 5000 });
await new Promise((r) => setTimeout(r, warmupMs));

const pids = descendantPids(mainPid);
// Let ps's own recent-CPU averaging window catch some of the running load.
await new Promise((r) => setTimeout(r, 500));
const cpuRunning = totalCpuPct(pids);

const h0 = await page.evaluate(() => window.readHeartbeat());
const t0 = Date.now();
const terminateCallMs = await page.evaluate(() => window.terminateWorker());

let last = null;
let deathAtMs = null;
let deathHeartbeat = null;
let cpuAfterDeath = null;
for (let elapsed = 0; elapsed <= POLL_BUDGET_MS; elapsed += POLL_MS) {
  const h = await page.evaluate(() => window.readHeartbeat());
  if (last !== null && h === last && deathAtMs === null) {
    deathAtMs = Date.now() - t0;
    deathHeartbeat = h;
  } else if (h !== last) {
    deathAtMs = null; // still moving; keep watching
  }
  last = h;
  if (deathAtMs !== null && elapsed - deathAtMs > 500) break; // confirmed frozen for 500ms, stop early
  await new Promise((r) => setTimeout(r, POLL_MS));
}

if (deathAtMs !== null) {
  cpuAfterDeath = totalCpuPct(descendantPids(mainPid));
}

await ctx.close();
rmSync(userDataDir, { recursive: true, force: true });

console.log(JSON.stringify({
  variant,
  mainPid,
  cpuBaselinePct: cpuBaseline,
  cpuRunningPct: cpuRunning,
  terminateCallMs,
  heartbeatAtTerminate: h0,
  deathAtMs,
  heartbeatAtDeath: deathHeartbeat,
  cpuAfterDeathPct: cpuAfterDeath,
  diedWithinBudget: deathAtMs !== null,
}));
