# Experiment 005 — stdout/stderr Capture Under Load

Extends [experiment 004](../004_static_wasi_hello/)'s static-page architecture. Instead
of one line, the WASM binary prints N lines to stdout and N to stderr, interleaved, in
a tight loop — 10, 1,000, and 100,000 — to find where the capture pipeline
(`browser_wasi_shim`'s `ConsoleStdout.lineBuffered` → one `postMessage` per line →
main-thread handling) costs something, and whether it's ever wrong.

Directly exercises the mechanism the MVL playground's Runtime output pane
depends on, which is only manually spot-checked there today, never stress-tested.

## Hypotheses

| # | Hypothesis | Status |
|---|-----------|--------|
| H1 | Per-line overhead stays roughly constant (small but non-zero) as N grows | **Refuted.** Per-line cost drops from 0.0425ms at N=10 to 0.0016ms at N=100,000 — a ~26x decrease, not a constant. See Finding 1. |
| H2 | stdout/stderr interleaving preserves per-stream ordering, but a cross-stream race is plausible | **Confirmed on ordering, not tested on interleaving-race specifically** — every run at every N had exact per-stream monotonic sequences (0..N-1, no gaps, no duplicates) across two independent `ConsoleStdout` callbacks. No cross-stream race was ever observed, but this doesn't rule one out under different scheduling — see Limitations. |
| H3 | Naive per-message DOM rendering becomes the bottleneck before the Worker/shim pipeline does | **Confirmed, and precisely quantified** — at N=100,000, DOM append adds ~780ms on top of the array-only baseline (352ms → 1135ms); at N=10 and N=1,000 the difference is within measurement noise. See Finding 2. |
| H4 | No lines are silently dropped, duplicated, or reordered at any tested N | **Confirmed at every tested N**, up to 200,000 total captured lines. |

## Methodology

- **Correctness**: each line is `OUT <i>` or `ERR <i>`, `i` a monotonic per-stream
  counter. The browser-side harness parses every received line back into its sequence
  number and checks `seq[k] === k` for all `k` — an exact-match check, not just a
  count.
- **Timing, two numbers per run, not one:**
  - `workerElapsedMs` — measured **inside the Worker**, wrapping only `wasi.start(instance)`. Covers WASM execution plus the N synchronous `postMessage` dispatch calls (structured-clone serialization). Does **not** include `fetch`/`WebAssembly.instantiate` or any main-thread work.
  - `mainThreadElapsedMs` — measured **on the main thread**, from just before `worker.postMessage({type:'run'})` to the last stdout/stderr message received. Includes fetch, instantiate, full execution, message-passing latency, and (when enabled) DOM rendering. This is closer to "how long until the user sees everything" than `workerElapsedMs` is.
- **DOM variants**: `?dom=1` appends one DOM node per received line (naive); `?dom=0` only counts/verifies in memory and renders one summary line at the end. Both always run the full correctness check.
- **Each measurement launches a fresh headless Chromium process** (`chromium.launch()` per `measure.mjs` invocation) — there is no shared warm browser across the N×dom matrix. This is a real limitation: small-N numbers are more exposed to fixed one-time costs (first navigation, JIT warmup — the same effect documented in experiment 004) than large-N numbers are, since the fixed cost is a smaller fraction of a bigger total. Finding 1 is best read with this in mind.

## Findings

### 1. Per-line overhead is dominated by a fixed cost, not a per-call cost — H1 refuted

| N | Total lines | Worker-side (ms) | ms/line |
|---|---|---|---|
| 10 | 20 | 0.85 | 0.0425 |
| 1,000 | 2,000 | 6.55 | 0.0033 |
| 100,000 | 200,000 | 326.75 | 0.0016 |

If `postMessage` cost per line were roughly constant, ms/line would stay flat across
the table. It drops by an order of magnitude from N=10 to N=1,000, then keeps
dropping (more slowly) to N=100,000. The honest read: there is a small fixed
per-run cost (browser/JIT warmup, consistent with experiment 004's own first-run
outlier) that dominates the N=10 case and amortizes away as N grows. **The
practical implication for a real playground is the opposite of the original
worry**: printing more lines doesn't get proportionally more expensive per line —
if anything it gets cheaper per line, up to whatever point DOM rendering (Finding 2)
takes over as the actual bottleneck.

### 2. DOM rendering, not the shim/postMessage pipeline, is the real cost at scale — H3 confirmed

| N | dom | Total lines | Worker-side (ms) | Main-thread total (ms) |
|---|---|---|---|---|
| 10 | 1 | 20 | 0.9 | 36.0 |
| 10 | 0 | 20 | 0.8 | 13.5 |
| 1,000 | 1 | 2,000 | 7.1 | 25.5 |
| 1,000 | 0 | 2,000 | 6.0 | 24.3 |
| 100,000 | 1 | 200,000 | 337.6 | 1,134.8 |
| 100,000 | 0 | 200,000 | 315.9 | 352.2 |

At N=10 and N=1,000 the dom=1 vs dom=0 difference is within noise (a few ms, likely
the fresh-browser-per-run effect from Finding 1, not DOM cost specifically). At
N=100,000 it is not noise: **naive per-line DOM append adds ~780ms** (352ms → 1,135ms,
a >3x increase) while the worker-side WASM execution time barely moves (316ms →
338ms). The pipeline that captures and delivers output is not what gets slow — 200,000
individually-appended DOM nodes is.

Notably, it does **not** hang or time out even at 200,000 nodes in headless
Chromium (60s budget, completed in ~1.1s) — slower, not broken.

### 3. Zero drops, duplicates, or reordering at any tested scale — H4 confirmed

Every run, every N, both dom variants: exact per-stream sequence match, exact line
counts, zero console errors. The capture pipeline's correctness held up to 200,000
total lines; nothing here suggests it would fail at even higher N, though this wasn't
tested past 100,000/stream.

## Limitations

- H2's "cross-stream race" was never observed, but this experiment doesn't
  specifically try to provoke one (e.g. by making one stream's writes artificially
  slower than the other's). Absence of evidence here is not strong evidence of
  absence.
- No shared-browser, multi-trial-per-N measurement was done (see Methodology) — the
  N=10 numbers in particular should be read as "N=10 in a freshly launched browser,"
  not "the true asymptotic per-line cost at N=10."

## Usage

```bash
./build.sh
./benchmark.sh                 # full N x dom matrix, ~10-15s total

# Manual:
python3 -m http.server 8899 --bind 127.0.0.1 --directory web
open "http://127.0.0.1:8899/index.html?n=1000&dom=1"
```

## Structure

```
005_stdout_capture_load/
├── README.md
├── build.sh
├── benchmark.sh              # runs N=10/1000/100000 x dom=0/1, verifies + reports
├── rust/
│   ├── Cargo.toml
│   └── src/main.rs           # prints N interleaved, per-stream-sequenced lines
└── web/
    ├── index.html            # ?n=&dom= query params; verifies + times in-page
    ├── worker.js
    ├── measure.mjs           # Playwright: one (N, dom) measurement
    └── package.json
    # web/vendor/, web/line_flood.wasm, web/node_modules/ — build.sh output, gitignored
```
