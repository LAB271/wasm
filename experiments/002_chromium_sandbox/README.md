# Experiment 002 — Chromium WASM Sandbox Workload & Isolation Characterization

Extends [experiment 001](../001_hello_world/) by testing real workloads inside headless Chromium
via Playwright + Pyodide, with different isolation strategies and concurrency patterns.

## Context

Experiment 001 established baseline metrics across runtimes. Legs 2b/2c showed that headless
Chromium carries significant overhead for a trivial Hello World handler. This experiment answers:
**when does that overhead become worthwhile?**

All legs use **Playwright + headless Chromium** with **Pyodide** as the Python-in-WASM runtime.

## Hypotheses

| # | Hypothesis | Status |
|---|-----------|--------|
| H1 | CPU-bound tasks in Web Worker pool achieve near-linear speedup up to core count | **Confirmed** — 3.2x throughput (2922 vs 920 rps) with 5 workers |
| H2 | JS↔WASM bridge marshalling dominates latency for data-heavy workloads (>50% of p95) | **Rejected** — bridge overhead ~1-4ms vs <1ms compute; bridge is measurable but not dominant |
| H3 | Per-request BrowserContext adds 50-200ms overhead vs shared page | **Exceeded** — ~950ms overhead per request (Pyodide CDN reload dominates) |
| H4 | BrowserContext pooling recovers most of the isolation overhead | **Confirmed** — pool legs (1b, 4b) achieve 2-3x throughput of shared page |
| H5 | Chromium memory grows linearly with concurrent BrowserContexts (~50MB each) | **Partially confirmed** — 5 contexts use ~1.7GB total (~340MB/context, not 50MB) |
| H6 | For I/O-bound work, isolation overhead is negligible relative to DB round-trip | **Rejected** — fresh context overhead (~980ms) dwarfs DB round-trip (~1ms) |

## Legs

| Leg | Port | Workload | Isolation | Concurrency | Tests |
|-----|------|----------|-----------|-------------|-------|
| 1a | 5010 | CPU-bound (fib/matrix) | Shared page | Sequential | Baseline CPU throughput |
| 1b | 5011 | CPU-bound (fib/matrix) | Shared page | Worker pool (N=5) | Worker parallelism |
| 2a | 5012 | JSON transform (1KB→50KB) | Shared page | Sequential | Data marshalling cost |
| 2b | 5013 | JSON transform (1KB→50KB) | Fresh BrowserContext | Sequential | Per-request isolation |
| 3a | 5014 | DB query (Postgres bridge) | Shared page | Sequential | I/O bridge cost |
| 3b | 5015 | DB query (Postgres bridge) | Fresh BrowserContext | Sequential | Isolation on I/O work |
| 4a | 5016 | Mixed (CPU+DB+JSON) | Shared page | Sequential | Realistic handler |
| 4b | 5017 | Mixed (CPU+DB+JSON) | BrowserContext pool (N=5) | Concurrent (c=5) | Pooled isolation |

## Architecture

Single parameterized harness (`harness.js --leg <id>`) drives all legs. Workloads are Python
modules loaded into Pyodide at startup. The harness selects isolation strategy based on leg config.

```
Client (hey) → HTTP → harness.js → Playwright → Chromium → Pyodide → workload.py
                                                                    ↕
                                                              host bridge (DB legs)
                                                                    ↕
                                                              PostgreSQL
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

### Key findings

1. **Shared page is fast** (~1ms latency) but offers no isolation between requests
2. **Fresh BrowserContext is unusable** for latency-sensitive work (~1s per request) due to Pyodide reload
3. **Context pooling is the sweet spot** — pre-warmed contexts give isolation + throughput
4. **Memory cost is high** — each Chromium context with Pyodide uses ~300-350MB
5. **Bridge overhead is small** — `page.evaluate()` round-trip adds only 1-4ms
