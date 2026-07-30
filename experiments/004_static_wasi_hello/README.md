# Experiment 004 — Static HTML Hello World, Zero Server

Every runtime in experiments 001–003 is launched by something before it can run: a
container, `wasmtime serve`, or Playwright driving headless Chromium. This experiment
tests the pattern `mvl-lang/mvl-playground` actually uses in production: a **static
HTML page with no server involved at execution time at all**. A server only ever
compiles source to WASM, once, ahead of time; a human opening a plain page is the
entire runtime.

## Mental model

```
rust/src/main.rs
      │
      ▼  (build.sh, ahead of time — never at page-load time)
web/hello_wasi.wasm  +  web/vendor/browser_wasi_shim/  (vendored, no CDN, no bundler)
      │
      ▼
index.html  →  new Worker(worker.js)  →  WebAssembly.instantiate()  →  stdout/stderr
                                          against @bjorn3/browser_wasi_shim
```

No container, no `wasmtime serve`, no Playwright required to make the page work —
only to script measuring it (see Methodology).

## Hypotheses

| # | Hypothesis | Status |
|---|-----------|--------|
| H1 | No-server cold start is the fastest of all measured legs so far | **Confirmed** — median 22.7ms, vs. hundreds of ms to seconds for every leg in experiment 001 |
| H2 | Artifact size is comparable to or smaller than experiment 001's Wasmtime leg | **Untestable as stated** — experiment 001's results table is still blank (`<!-- populated by benchmark.sh -->` as of this writing), so there is nothing to compare against yet. This experiment's own number: 39.4KB (.wasm only), 85.6KB (full page weight incl. vendored shim JS) |
| H3 | A raw `wasm32-wasip1` core module is required, not `wasm32-wasip2` | **Confirmed, precisely** — see Finding 2 below. The failure isn't shim-specific; it happens one layer down, in the browser's own `WebAssembly.compile()` |

## Methodology

- **Cold start**: `performance.now()` at navigation start (implicit — it's `performance`'s own time origin) to the moment the Worker posts its `done` message, captured on `window.__exp004.coldStartMs` and read back via Playwright. Playwright automates the *measurement* only — the page itself was verified to run correctly in an ordinary (non-automated) browser tab first.
- **Artifact size**: `wc -c` equivalent (`human_size` from `../001_hello_world/lib/bench.sh`) on the `.wasm` file alone, and separately on the full set of static assets a real page load fetches (HTML + worker JS + vendored shim JS + wasm).
- 10 runs; reported as min/median/max, not just one number — run 1 is consistently an outlier (see Finding 3).

## Findings

### 1. `file://` does not work; a static server is required — and the reason is specific

Tested directly rather than assumed. Opening `index.html` via `file://` fails with:

```
Failed to construct 'Worker': Script at 'file:///.../worker.js' cannot be accessed from origin 'null'.
```

Module-type Workers are blocked under the `file://` origin (`null` origin, treated as
cross-origin for module scripts specifically). Any static HTTP server — this
experiment uses `python3 -m http.server` — resolves it; no build step, dynamic
content, or backend logic is needed, just *something* serving the files over `http://`.

### 2. `wasm32-wasip2` output fails at `WebAssembly.compile()`, not at the WASI-import layer

Compiled the identical `main.rs` to `wasm32-wasip2` and tried to load it with the
plain `WebAssembly.compile()` API (no shim involved yet):

```
WebAssembly.compile(): expected version 01 00 00 00, found 0d 00 01 00 @+4
```

`wasm32-wasip2` emits the component-model binary format, which isn't a core module at
all — the browser's own WebAssembly parser rejects it outright. This has nothing to
do with `@bjorn3/browser_wasi_shim` specifically; it would fail identically against
any code using the standard `WebAssembly.instantiate`/`compile` API. Building for
`wasm32-wasip1` is not a preference, it's the only target that produces something a
browser can even parse as a module.

### 3. First-run outlier

Run 1 measured 100.6ms against a median of 22.7ms across the other 9 runs — consistent
with Chromium's first-navigation JIT/compilation warmup rather than noise. Reported
honestly in the table below rather than dropped; the min/median/max spread makes it
visible without needing a discarded-outliers footnote.

## Results

Measured on this machine, 10 runs, `RUNS=10 ./benchmark.sh`:

| Metric | Value |
|---|---|
| Cold start, 10 runs (min / median / max, ms) | 22.2 / 22.7 / 100.6 |
| Artifact size (`.wasm` only) | 39.4KB |
| Total page weight (html + worker.js + vendored shim + wasm, no bundler) | 85.6KB |
| Requires a running process at view time? | No — static files only |

## Usage

```bash
./build.sh        # compile rust/ to wasm32-wasip1, vendor the shim — do this once
./benchmark.sh     # starts a throwaway static server, runs 10 measurements, tears down

# Manual check — start a static server yourself and open the page:
python3 -m http.server 8899 --bind 127.0.0.1 --directory web
open http://127.0.0.1:8899/index.html
```

## Structure

```
004_static_wasi_hello/
├── README.md
├── build.sh              # compile + vendor, ahead of time
├── benchmark.sh           # cold-start measurement harness (starts/stops its own server)
├── rust/
│   ├── Cargo.toml         # target wasm32-wasip1
│   ├── Cargo.lock
│   └── src/main.rs        # the entire "workload": println!("Hello World")
└── web/
    ├── index.html         # the static page — works in any browser tab, no automation needed
    ├── worker.js           # instantiates the wasm against the vendored shim
    ├── measure.mjs         # Playwright: one cold-start measurement
    ├── package.json
    └── package-lock.json
    # web/vendor/, web/hello_wasi.wasm, web/node_modules/ are build.sh output — gitignored
```
