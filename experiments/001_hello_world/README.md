# Experiment 001 — Hello World Benchmark

Validates the core claim from
[AWS's Stealth Container Killer](https://aws.plainenglish.io/awss-stealth-container-killer-we-replaced-docker-with-a-browser-and-slashed-costs-by-60-43fceea80b15):
that WASM runtimes can replace Docker containers for serverless-style workloads with lower cold
starts, smaller artifacts, and reduced memory.

Legs 1–3 implement the same handler. Legs 4a/4b/4c extend the experiment with
database access to measure whether the WASM host bridge pattern adds meaningful
latency compared to a traditional direct database connection.

All three Hello World legs implement the same handler:

```python
def handle(request):
    return {"message": "Hello World", "timestamp": time.time()}
```

---

## Hypotheses

| # | Hypothesis | Status |
|---|-----------|--------|
| H1 | **Artifact size**: Flask/Podman image > Pyodide/Chromium runtime > Wasmtime `.wasm` binary | — |
| H2 | **Cold start**: Podman slowest (~500ms+); Wasmtime fastest (<50ms); Pyodide/Chromium in between (~2–5s due to Chromium launch + Pyodide WASM init) | — |
| H3 | **Memory**: Chromium process heaviest (300MB+); Flask/Podman moderate (~50MB); Wasmtime lightest (<10MB) | — |
| H4 | **Warm p50**: All three comparable once runtime is loaded; Wasmtime expected fastest raw handler | — |
| H5 | **Bridge overhead vs direct**: Negligible — dominated by actual query execution time | — |
| H6 | **Connection pool location**: Host-side pool is equivalent to in-process pool | — |
| H7 | **Double-hop latency**: WASM→sidecar→Postgres adds measurable but acceptable overhead vs single-hop | — |

*Status column: fill with **confirmed** / **refuted** / **partially confirmed** after running `benchmark.sh`.*

---

## Methodology

- **Warm benchmark**: `hey -n 1000 -c 1` (1000 sequential requests, single connection) — identical for all legs
- **Cold start**: wall-clock time from process launch to first successful `curl /` response
- **Memory RSS**: `ps -o rss= -p $PID` captured after the warm benchmark completes
- **Artifact size**: container image bytes (Leg 1), `node_modules` directory (Leg 2), `.wasm` binary (Leg 3)
- **Note on legs 4a/4b**: Leg 4a uses Flask's single-threaded dev server while Leg 4b uses Node.js's async event loop. With `-c 1` (single concurrency) this is a fair comparison, but results would diverge under concurrent load

---

## Results

*Run `./benchmark.sh` to populate these tables.*

### Hello World (legs 1–3)

| Metric | Leg 1 Flask/Podman | Leg 2 Pyodide/Chrome | Leg 3 Wasmtime |
|---|---|---|---|
| Artifact size | | | |
| Cold start (ms) | | | |
| Memory RSS (MB) | | | |
| hey p50 (ms) | | | |
| hey p99 (ms) | | | |
| hey req/s | | | |

### Postgres DB query (legs 4a/4b/4c)

| Metric | Leg 4a Flask+psycopg2 | Leg 4b Pyodide+pg bridge | Leg 4c Wasmtime+sidecar |
|---|---|---|---|
| Artifact size | | | |
| Cold start (ms) | | | |
| Memory RSS (MB) | | | |
| hey p50 (ms) | | | |
| hey p99 (ms) | | | |
| hey req/s | | | |

---

## Legs

| Leg | Runtime | Port | Entry |
|-----|---------|------|-------|
| 1 | Flask in Podman/Docker container | 5001 | `leg1_flask_docker/run.sh` |
| 2 | Python via Pyodide in headless Chromium (Node.js) | 5002 | `leg2_pyodide_chromium/run.sh` |
| 3 | Rust compiled to `wasm32-wasip2`, served via `wasmtime serve` | 5003 | `leg3_wasmtime/run.sh` |
| 4a | Flask + psycopg2 → Postgres (direct connection) | 5004 | `leg4a_flask_postgres/run.sh` |
| 4b | Pyodide + Node.js pg bridge → Postgres (host bridge) | 5005 | `leg4b_wasm_postgres_bridge/run.sh` |
| 4c | Rust/Wasmtime + Node.js sidecar → Postgres (HTTP bridge) | 5006 | `leg4c_wasmtime_postgres/run.sh` |

Each leg can also be run standalone for debugging.

## Prerequisites

Run `../../install.sh` from the repo root to verify your environment.
