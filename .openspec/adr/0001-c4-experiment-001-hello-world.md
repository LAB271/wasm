# C4 Context: Experiment 001 — Hello World Benchmark

> Source: #1 — feat: experiment 001_hello_world — benchmark Flask/Podman vs Pyodide/Chromium vs Wasmtime

## System Context

A benchmark experiment that runs the same "Hello World" HTTP handler across three runtimes
(container, browser-WASM, native-WASM) to validate whether WASM runtimes can replace Docker
containers for serverless-style workloads with lower cold-start times, smaller artifact sizes,
and reduced memory footprint.

## Containers

| Container | Path | Role |
|-----------|------|------|
| Experiment README | `experiments/001_hello_world/README.md` | Hypotheses, methodology, and results table |
| Benchmark harness | `experiments/001_hello_world/benchmark.sh` | Orchestrates all three legs, emits markdown table |
| Leg 1 — Flask/Podman | `experiments/001_hello_world/leg1_flask_docker/` | Python Flask app in a container (Podman preferred, Docker fallback) on port 5001 |
| Leg 2a — Pyodide/Node | `experiments/001_hello_world/leg2a_pyodide_node/` | Pyodide WASM runtime in Node.js (no browser), Node HTTP server on port 5002 |
| Leg 2b — Pyodide/Chromium | `experiments/001_hello_world/leg2b_pyodide_chromium/` | Puppeteer headless Chrome + Pyodide loaded inside browser, Node HTTP proxy on port 5008 |
| Leg 3 — Wasmtime | `experiments/001_hello_world/leg3_wasmtime/` | Rust compiled to `wasm32-wasip2`, served via `wasmtime serve` on port 5003 |

## Constraints

- All three legs **must expose HTTP** on localhost (5001, 5002, 5003) so `ab` applies uniformly
- Leg 1: `python:3.12-slim` + Flask only — no extras. Uses **Podman** (preferred, rootless/daemonless) with **Docker** as fallback. `run.sh` must detect the available runtime via `$CONTAINER_CMD` (set by `install.sh`) rather than hardcoding either
- Leg 2: Puppeteer (headless Chrome) + Pyodide npm package; Python handler runs inside Pyodide; Node HTTP server proxies requests into the WASM runtime
- Leg 3: Rust compiled to `wasm32-wasip2`, served via `wasmtime serve --addr 127.0.0.1:5003`; implements `wasi:http/incoming-handler` (WASI HTTP proxy component model)
- Each leg must be runnable standalone via its `run.sh` on a clean Mac with prerequisites installed
- **Warm benchmark**: `hey -n 1000 -c 1` (1000 sequential requests, concurrency 1) — identical invocation for all three legs
- **Cold start**: measured with `time` from process launch to first successful `curl` response
- `benchmark.sh` must capture all measurements programmatically and emit a markdown table

## Failure Conditions

- Any leg's `run.sh` exits non-zero on a clean Mac with prerequisites installed
- Any leg does not serve HTTP (all three must be `ab`-able)
- Leg 1 hardcodes `docker` or `podman` instead of using `$CONTAINER_CMD`
- `benchmark.sh` does not use `hey -n 1000 -c 1` for warm invocation on all three legs
- `benchmark.sh` does not emit a markdown comparison table
- `README.md` is missing the hypotheses section
- Measurements are manual/narrative rather than script-captured
- Legs implement different business logic (must be semantically equivalent across all three)
- Leg 3 uses a native HTTP server instead of `wasmtime serve` (must go through the WASM component)
- Any component file exceeds 150 lines (keep legs minimal and focused)

## Full Prompt Contract

```
GOAL:
Produce a working experiments/001_hello_world/ directory with three runnable legs
and a benchmark script that outputs a comparison table. All three legs serve HTTP on
localhost (ports 5001, 5002, 5003) so ab can be used uniformly.

The same logic runs in all three legs:
  def handle(request):
      return {"message": "Hello World", "timestamp": time.time()}

Hypotheses (documented in README.md, to be validated by benchmark results):
1. Artifact size: Flask/Podman image > Pyodide/Chromium runtime > Wasmtime .wasm binary
2. Cold start: Podman slowest (~500ms+); Wasmtime fastest (<50ms); Pyodide/Chromium in between (~2–5s)
3. Memory: Chromium process heaviest (300MB+); Flask/Podman moderate (~50MB); Wasmtime lightest (<10MB)
4. Warm p50: All three comparable once runtime is loaded; Wasmtime expected fastest raw handler

CONSTRAINTS:
- All three legs must expose HTTP on localhost (5001, 5002, 5003)
- Leg 1: python:3.12-slim + Flask, $CONTAINER_CMD detection (Podman preferred, Docker fallback)
- Leg 2: Puppeteer + Pyodide npm; Python handler inside Pyodide; Node HTTP proxy
- Leg 3: Rust wasm32-wasip2, wasmtime serve --addr 127.0.0.1:5003, wasi:http/incoming-handler
- hey -n 1000 -c 1 for warm benchmark, identical for all legs
- benchmark.sh must emit markdown table with all metrics

FORMAT:
experiments/001_hello_world/
├── README.md
├── benchmark.sh
├── leg1_flask_docker/
│   ├── Dockerfile
│   ├── app.py
│   └── run.sh
├── leg2_pyodide_chromium/
│   ├── package.json
│   ├── harness.js
│   └── run.sh
└── leg3_wasmtime/
    ├── Cargo.toml
    ├── src/main.rs
    └── run.sh

FAILURE CONDITIONS:
- Any leg's run.sh exits non-zero on a clean Mac
- Any leg does not serve HTTP
- Leg 1 hardcodes docker or podman
- benchmark.sh does not use hey -n 1000 -c 1
- benchmark.sh does not emit a markdown table
- README.md missing hypotheses section
- Measurements are manual rather than script-captured
- Legs implement different business logic
- Leg 3 uses native HTTP server instead of wasmtime serve
- Any file exceeds 150 lines
```
