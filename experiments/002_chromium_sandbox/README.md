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
| H1 | CPU-bound tasks in Web Worker pool achieve near-linear speedup up to core count | — |
| H2 | JS↔WASM bridge marshalling dominates latency for data-heavy workloads (>50% of p99) | — |
| H3 | Per-request BrowserContext adds 50-200ms overhead vs shared page | — |
| H4 | BrowserContext pooling recovers most of the isolation overhead | — |
| H5 | Chromium memory grows linearly with concurrent BrowserContexts (~50MB each) | — |
| H6 | For I/O-bound work, isolation overhead is negligible relative to DB round-trip | — |

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
| Warm latency p50/p99 (ms) | `hey -n 1000 -c 1` (sequential) or `hey -n 1000 -c 5` (concurrent) |
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

_Results will be filled after running `make bench`._
