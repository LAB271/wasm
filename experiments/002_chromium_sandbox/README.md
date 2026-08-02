# Experiment 002 — Chromium WASM Sandbox Workload & Isolation Characterization

Extends [experiment 001](../001_hello_world/) by testing real workloads inside headless Chromium
via Playwright + Pyodide, with different isolation strategies and concurrency patterns.

## Context

Experiment 001 established baseline metrics across runtimes. Legs 2b/2c showed that headless
Chromium carries significant overhead for a trivial Hello World handler. This experiment answers:
**when does that overhead become worthwhile?**

Legs 1-4 use **Playwright + headless Chromium** with **Pyodide** as the Python-in-WASM runtime.
Legs 5a/5b add native-compiled WASM (Rust, AssemblyScript) run directly in V8 — no Pyodide, no
Python interpreter — to isolate how much of Pyodide's overhead is inherent to running WASM in a
browser versus specific to the Pyodide runtime itself.

## Hypotheses

| # | Hypothesis | Status |
|---|-----------|--------|
| H1 | CPU-bound tasks in Web Worker pool achieve near-linear speedup up to core count | **Confirmed** — 3.2x throughput (2922 vs 920 rps) with 5 workers |
| H2 | JS↔WASM bridge marshalling dominates latency for data-heavy workloads (>50% of p95) | **Rejected** — bridge overhead ~1-4ms vs <1ms compute; bridge is measurable but not dominant |
| H3 | Per-request BrowserContext adds 50-200ms overhead vs shared page | **Exceeded** — ~950ms overhead per request (Pyodide CDN reload dominates) |
| H4 | BrowserContext pooling recovers most of the isolation overhead | **Confirmed** — pool legs (1b, 4b) achieve 2-3x throughput of shared page |
| H5 | Chromium memory grows linearly with concurrent BrowserContexts (~50MB each) | **Partially confirmed** — 5 contexts use ~1.7GB total (~340MB/context, not 50MB) |
| H6 | For I/O-bound work, isolation overhead is negligible relative to DB round-trip | **Rejected** — fresh context overhead (~980ms) dwarfs DB round-trip (~1ms) |
| H7 | Native WASM (Rust/AssemblyScript) in V8 eliminates Pyodide's interpreter/CDN-load overhead, achieving cold start <100ms and memory <100MB for identical CPU-bound work | **Partially confirmed** — cold start drops ~2.9x (1790→622/615ms) and memory drops ~1.6x (602→375/374MB) vs Pyodide, but stays well above the <100ms/<100MB targets: headless Chromium itself has a ~600ms/~240MB floor that no WASM runtime choice avoids |

## Legs

| Leg | Port | Workload | Runtime | Isolation | Concurrency | Tests |
|-----|------|----------|---------|-----------|-------------|-------|
| 1a | 5010 | CPU-bound (fib/matrix) | Pyodide | Shared page | Sequential | Baseline CPU throughput |
| 1b | 5011 | CPU-bound (fib/matrix) | Pyodide | Shared page | Worker pool (N=5) | Worker parallelism |
| 2a | 5012 | JSON transform (1KB→50KB) | Pyodide | Shared page | Sequential | Data marshalling cost |
| 2b | 5013 | JSON transform (1KB→50KB) | Pyodide | Fresh BrowserContext | Sequential | Per-request isolation |
| 3a | 5014 | DB query (Postgres bridge) | Pyodide | Shared page | Sequential | I/O bridge cost |
| 3b | 5015 | DB query (Postgres bridge) | Pyodide | Fresh BrowserContext | Sequential | Isolation on I/O work |
| 4a | 5016 | Mixed (CPU+DB+JSON) | Pyodide | Shared page | Sequential | Realistic handler |
| 4b | 5017 | Mixed (CPU+DB+JSON) | Pyodide | BrowserContext pool (N=5) | Concurrent (c=5) | Pooled isolation |
| 5a | 5018 | CPU-bound (fib/matrix) | Rust/WASM (native, no Pyodide) | Shared page | Sequential | Native WASM baseline |
| 5b | 5019 | CPU-bound (fib/matrix) | AssemblyScript/WASM (native, no Pyodide) | Shared page | Sequential | Native WASM baseline |

## Architecture

Single parameterized harness (`harness.js --leg <id>`) drives all legs. For legs 1-4, workloads are
Python modules loaded into Pyodide at startup. The harness selects isolation strategy based on leg
config.

```
Client (hey) → HTTP → harness.js → Playwright → Chromium → Pyodide → workload.py
                                                                    ↕
                                                              host bridge (DB legs)
                                                                    ↕
                                                              PostgreSQL
```

Legs 5a/5b bypass Pyodide entirely: `harness.js` reads the compiled `.wasm` binary, base64-encodes
it, and hands it to a `page.evaluate()` call that instantiates it directly via
`WebAssembly.instantiate()` and calls the exported `handle()` — no interpreter, no CDN fetch, no
Python object marshalling.

```
Client (hey) → HTTP → harness.js → Playwright → Chromium → WebAssembly.instantiate() → handle()
```

## Metrics

| Metric | How measured |
|--------|-------------|
| Cold start (ms) | Time from process launch to first HTTP 200 |
| Memory RSS (MB) | Sum of Node + Chromium process tree RSS |
| Warm latency p50/p95 (ms) | `hey -n 1000 -c 1` (sequential) or `hey -n 1000 -c 5` (concurrent) |
| Requests/sec | From `hey` output |
| JS↔WASM bridge overhead (ms) | `process.hrtime.bigint()` around `page.evaluate()` |
| Context create/destroy (ms) | Per-request BrowserContext lifecycle (legs 2b, 3b) |
| Worker spawn (ms) | Worker page initialization time (leg 1b) |

## Usage

```bash
brew install bats-core hey  # one-time
make test                   # run unit tests
make bench-quick            # quick benchmark (HEY_N=10)
make bench                  # full benchmark (HEY_N=1000)

# Run a single leg
node harness.js 2a          # Start leg 2a server on port 5012
```

## Results

### CPU-bound workload (legs 1a/1b)

| Metric | 1a Shared/Sequential | 1b Worker Pool (c=5) |
|--------|---------------------|---------------------|
| Cold start (ms) | 2,257 | 5,583 |
| Memory RSS (MB) | 593 | 1,791 |
| hey p50 (ms) | 1.0 | 1.3 |
| hey p95 (ms) | 1.6 | — |
| hey req/s | 920 | 2,922 |

Worker pool achieves **3.2x throughput** at the cost of 3x memory and 2.5x cold start.

### JSON transform (legs 2a/2b)

| Metric | 2a Shared/Sequential | 2b Fresh Context/Sequential |
|--------|---------------------|----------------------------|
| Cold start (ms) | 1,685 | 1,659 |
| Memory RSS (MB) | 586 | 350 |
| hey p50 (ms) | 0.6 | 946 |
| hey p95 (ms) | 1.6 | — |
| hey req/s | 1,604 | 1 |

Fresh BrowserContext is **~1,600x slower** — each request reloads Pyodide from CDN (~950ms).

### DB query (legs 3a/3b)

| Metric | 3a Shared/Sequential | 3b Fresh Context/Sequential |
|--------|---------------------|----------------------------|
| Cold start (ms) | 1,790 | 1,619 |
| Memory RSS (MB) | 595 | 330 |
| hey p50 (ms) | 1.1 | 982 |
| hey p95 (ms) | — | — |
| hey req/s | 697 | 1 |

Same pattern: fresh context overhead dwarfs the actual DB query cost.

### Mixed workload (legs 4a/4b)

| Metric | 4a Shared/Sequential | 4b Context Pool (c=5) |
|--------|---------------------|----------------------|
| Cold start (ms) | 1,805 | 5,627 |
| Memory RSS (MB) | 594 | 1,451 |
| hey p50 (ms) | 1.5 | 2.4 |
| hey p95 (ms) | — | — |
| hey req/s | 554 | 1,455 |

Context pool achieves **2.6x throughput** — pre-initialized contexts avoid Pyodide reload.

### CPU-bound: Pyodide vs native WASM (legs 1a/5a/5b)

Legs 1a, 5a, and 5b were re-measured together in one run (same machine, same `hey -n 1000 -c 1`)
for an apples-to-apples comparison — values differ slightly from the 1a/1b table above due to
normal run-to-run variance, but are consistent with it (~600MB / ~1ms range).

| Metric | 1a Pyodide | 5a Rust/WASM | 5b AssemblyScript/WASM |
|--------|-----------|--------------|-------------------------|
| Cold start (ms) | 1,790 | 622 | 615 |
| Memory RSS (MB) | 602 (node:133+chrome:469) | 375 (node:134+chrome:241) | 374 (node:134+chrome:240) |
| hey p50 (ms) | 0.8 | 0.3 | 0.3 |
| hey p95 (ms) | 1.0 | 0.4 | 0.5 |
| hey req/s | 1,246 | 3,343 | 2,820 |

Dropping Pyodide cuts cold start by **~2.9x** (1,790ms → ~620ms) and memory by **~1.6x** (602MB →
~375MB), and roughly triples throughput. But it doesn't get anywhere near the "<100ms / <100MB"
targets in H7 — headless Chromium itself (page + context launch, no workload at all) accounts for
most of what's left: ~600ms and ~240MB of the native-WASM legs' footprint is Chromium/Playwright
overhead, not WASM-runtime overhead. Rust and AssemblyScript perform almost identically once
Pyodide is out of the picture — the interpreter, not the WASM engine, was the bottleneck all along.

### Key findings

1. **Shared page is fast** (~1ms latency) but offers no isolation between requests
2. **Fresh BrowserContext is unusable** for latency-sensitive work (~1s per request) due to Pyodide reload
3. **Context pooling is the sweet spot** — pre-warmed contexts give isolation + throughput
4. **Memory cost is high** — each Chromium context with Pyodide uses ~300-350MB
5. **Bridge overhead is small** — `page.evaluate()` round-trip adds only 1-4ms
6. **Pyodide is most of the overhead, but not all of it** — native WASM (legs 5a/5b) cuts cold start ~2.9x and memory ~1.6x vs Pyodide, but headless Chromium's own ~600ms/~240MB floor means the "spin up WASM in a browser" story never gets near native-process numbers
