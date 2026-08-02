// inline.ts — fetch vs base64-inline WASM loading, measured.
//
// Standalone comparison page: does NOT reuse app.ts's game/solver logic.
// Loads the same engine two ways and reports request count, bytes
// transferred, decode time, WebAssembly.instantiate time, and total
// time-to-first-score_guess for each. Also proves the inline-loaded module
// actually works by running it and diffing against the fetch-loaded module.
//
// See README.md ("Fetch vs. inline-base64 loading") for the measured numbers
// and the honest caveats (localhost RTT ≈ 0, so timing deltas here are noise —
// request count and bytes are the numbers that generalize).

interface WasmExports {
  score_guess(s0: number, s1: number, s2: number, s3: number, g0: number, g1: number, g2: number, g3: number): number;
}

interface MethodResult {
  requests: number;
  bytes: number;
  decodeMs: number;
  instantiateMs: number;
  totalMs: number;
  exports: WasmExports;
}

const CASES: [number, number, number, number, number, number, number, number][] = [
  [0, 1, 2, 3, 0, 1, 2, 3],
  [0, 1, 2, 3, 3, 2, 1, 0],
  [0, 0, 1, 2, 0, 1, 1, 3],
  [5, 4, 3, 2, 2, 3, 4, 5],
  [1, 1, 1, 1, 2, 2, 2, 2],
];

function engineName(): "rust" | "as" {
  const p = new URLSearchParams(location.search).get("engine");
  return p === "as" ? "as" : "rust";
}

// Sum transfer bytes for resource-timing entries whose name contains `token`
// (a cache-busting marker unique to one measurement run, so repeated runs
// and the two methods never cross-contaminate each other's counts).
function resourceStats(token: string): { requests: number; bytes: number } {
  const entries = performance.getEntriesByType("resource") as PerformanceResourceTiming[];
  const matches = entries.filter((e) => e.name.includes(token));
  const bytes = matches.reduce((sum, e) => sum + (e.transferSize || e.encodedBodySize || 0), 0);
  return { requests: matches.length, bytes };
}

async function measureFetch(name: string, token: string): Promise<MethodResult> {
  const t0 = performance.now();
  const res = await fetch(`engine-${name}.wasm?cb=${token}`);
  const t1 = performance.now();
  const bytes = await res.arrayBuffer();
  const t2 = performance.now();
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const t3 = performance.now();
  const { requests, bytes: transferred } = resourceStats(token);
  return {
    requests,
    bytes: transferred,
    decodeMs: t2 - t1,
    instantiateMs: t3 - t2,
    totalMs: t3 - t0,
    exports: instance.exports as unknown as WasmExports,
  };
}

async function measureInline(name: string, token: string): Promise<MethodResult> {
  const t0 = performance.now();
  const mod = await import(`../engine-${name}.b64.js?cb=${token}`);
  const t1 = performance.now();
  const binary = atob(mod.WASM_B64);
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  const t2 = performance.now();
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const t3 = performance.now();
  const { requests, bytes: transferred } = resourceStats(token);
  return {
    requests,
    bytes: transferred,
    decodeMs: t2 - t1,
    instantiateMs: t3 - t2,
    totalMs: t3 - t0,
    exports: instance.exports as unknown as WasmExports,
  };
}

function fmtMs(n: number): string {
  return `${n.toFixed(2)} ms`;
}

function renderTable(fetchR: MethodResult, inlineR: MethodResult): string {
  const rows: [string, string, string][] = [
    ["Requests", String(fetchR.requests), String(inlineR.requests)],
    ["Bytes transferred", `${fetchR.bytes} B`, `${inlineR.bytes} B`],
    ["Decode time", fmtMs(fetchR.decodeMs), fmtMs(inlineR.decodeMs)],
    ["WebAssembly.instantiate", fmtMs(fetchR.instantiateMs), fmtMs(inlineR.instantiateMs)],
    ["Total time-to-first-call", fmtMs(fetchR.totalMs), fmtMs(inlineR.totalMs)],
  ];
  const body = rows
    .map(([label, a, b]) => `<tr><td>${label}</td><td>${a}</td><td>${b}</td></tr>`)
    .join("");
  return `<table class="compare-table">
    <thead><tr><th></th><th>fetch()</th><th>inline base64</th></tr></thead>
    <tbody>${body}</tbody>
  </table>`;
}

function renderParity(fetchR: MethodResult, inlineR: MethodResult): string {
  let allMatch = true;
  const rows = CASES.map((args) => {
    const a = fetchR.exports.score_guess(...args);
    const b = inlineR.exports.score_guess(...args);
    const ok = a === b;
    if (!ok) allMatch = false;
    return `<tr class="${ok ? "pass" : "fail"}"><td>${args.join(",")}</td><td>${a}</td><td>${b}</td><td>${ok ? "match" : "MISMATCH"}</td></tr>`;
  }).join("");
  return `<p class="${allMatch ? "pass" : "fail"}">${allMatch ? `✓ all ${CASES.length} cases match — inline module genuinely works` : `✗ mismatch found — inline module is NOT equivalent`}</p>
  <table class="compare-table">
    <thead><tr><th>args</th><th>fetch() result</th><th>inline result</th><th></th></tr></thead>
    <tbody>${rows}</tbody>
  </table>`;
}

async function runComparison(): Promise<void> {
  const name = engineName();
  const resultsEl = document.getElementById("results") as HTMLElement;
  const parityEl = document.getElementById("parity") as HTMLElement;
  resultsEl.textContent = "running…";
  parityEl.textContent = "";

  const token = `run${Date.now()}`;
  try {
    const [fetchR, inlineR] = await Promise.all([
      measureFetch(name, `${token}f`),
      measureInline(name, `${token}i`),
    ]);
    resultsEl.innerHTML = renderTable(fetchR, inlineR);
    parityEl.innerHTML = renderParity(fetchR, inlineR);
  } catch (err) {
    resultsEl.innerHTML = `<p class="fail">comparison failed: ${err}</p>`;
    console.error(err);
  }
}

async function testCrossOrigin(): Promise<void> {
  const name = engineName();
  const portInput = document.getElementById("foreign-port") as HTMLInputElement;
  const foreignPort = portInput.value.trim() || "8011";
  const corsResultEl = document.getElementById("cors-result") as HTMLElement;
  corsResultEl.textContent = "testing…";

  const foreignOrigin = `${location.protocol}//${location.hostname}:${foreignPort}`;
  const lines: string[] = [];

  // Fetch of the .wasm binary from a foreign origin — this is the request
  // that CORS (or its absence) actually gates.
  try {
    const t0 = performance.now();
    const res = await fetch(`${foreignOrigin}/engine-${name}.wasm?cb=cors${Date.now()}`, { mode: "cors" });
    const bytes = await res.arrayBuffer();
    const t1 = performance.now();
    lines.push(`<p class="pass">✓ cross-origin fetch of engine-${name}.wasm from ${foreignOrigin} SUCCEEDED (${bytes.byteLength} B in ${fmtMs(t1 - t0)}) — that server is sending CORS headers.</p>`);
  } catch (err) {
    lines.push(`<p class="fail">✗ cross-origin fetch of engine-${name}.wasm from ${foreignOrigin} BLOCKED: ${err} — start that server with the default (CORS-enabled) flags to see it succeed, or keep --no-cors to see this failure on purpose.</p>`);
  }

  // The inline module never touches the foreign origin at all — it's part of
  // this page's own same-origin assets, so there is nothing for CORS to gate.
  try {
    const token = `crossinline${Date.now()}`;
    const inlineR = await measureInline(name, token);
    const sample = inlineR.exports.score_guess(0, 1, 2, 3, 0, 1, 2, 3);
    lines.push(`<p class="pass">✓ inline base64 module loaded from THIS page's own origin (never contacted ${foreignOrigin}) — score_guess(0,1,2,3,0,1,2,3) = ${sample}. Works regardless of the foreign server's CORS policy, because the request that CORS would gate never happens.</p>`);
  } catch (err) {
    lines.push(`<p class="fail">✗ inline module failed unexpectedly: ${err}</p>`);
  }

  corsResultEl.innerHTML = lines.join("");
}

function main(): void {
  document.getElementById("run-btn")!.addEventListener("click", () => void runComparison());
  document.getElementById("cors-btn")!.addEventListener("click", () => void testCrossOrigin());
  void runComparison();
}

main();
