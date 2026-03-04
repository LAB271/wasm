# Experiment 001 — Hello World Benchmark

Validates the core claim from
[AWS's Stealth Container Killer](https://aws.plainenglish.io/awss-stealth-container-killer-we-replaced-docker-with-a-browser-and-slashed-costs-by-60-43fceea80b15):
that WASM runtimes can replace Docker containers for serverless-style workloads with lower cold
starts, smaller artifacts, and reduced memory.

All three legs implement the same handler:

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

*Status column: fill with **confirmed** / **refuted** / **partially confirmed** after running `benchmark.sh`.*

---

## Methodology

- **Warm benchmark**: `hey -n 1000 -c 1` (1000 sequential requests, single connection) — identical for all legs
- **Cold start**: wall-clock time from process launch to first successful `curl /` response
- **Memory RSS**: `ps -o rss= -p $PID` captured after the warm benchmark completes
- **Artifact size**: container image bytes (Leg 1), `node_modules` directory (Leg 2), `.wasm` binary (Leg 3)

---

## Results

*Run `./benchmark.sh` to populate this table.*

| Metric | Leg 1 Flask/Podman | Leg 2 Pyodide/Chrome | Leg 3 Wasmtime |
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

Each leg can also be run standalone for debugging.

## Prerequisites

Run `../../install.sh` from the repo root to verify your environment.
