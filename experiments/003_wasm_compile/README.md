# Experiment 003 — Compile JS & Python to .wasm

Compile a Hello World JSON API in **JavaScript** and **Python** to a
self-contained `.wasm` binary, then run it natively on macOS and inside a
podman container.

## Mental Model

```
Your .py or .js
      │
      ▼  (spin build / componentize-py)
   app.wasm  ◄── portable, sandboxed binary
      │
      ├──► Native macOS
      │    ├── spin up          (Spin embeds wasmtime)
      │    └── wasmtime serve   (raw runtime, wasi-http components only)
      │
      └──► Podman container
           └── Spin image (ghcr.io/fermyon/spin)
               └── your app.wasm mounted or copied in
```

## Legs

| Leg | Source | Toolchain | Runner | Port |
|-----|--------|-----------|--------|------|
| **1a** | `js-spin/src/index.js` | Spin http-js | `spin up` macOS | 5030 |
| **1b** | `js-spin/src/index.js` | Spin http-js | Spin-in-podman | 5031 |
| **2a** | `python-raw/app.py` | componentize-py (raw) | `wasmtime serve` macOS | 5032 |
| **2b** | `python-spin/app.py` | Spin http-py | `spin up` macOS | 5033 |
| **2c** | `python-spin/app.py` | Spin http-py | Spin-in-podman | 5034 |
| **3**  | `rust/src/lib.rs` | cargo wasm32-wasip2 | `wasmtime serve` macOS | 5035 |

Legs 1b and 2c use `Containerfile` (Spin-in-podman) — not Docker's
`--platform wasi/wasm` shim (not supported by podman).

## Hypotheses

| # | Hypothesis | Expected outcome |
|---|------------|-----------------|
| H1 | componentize-py .wasm (CPython embedded) is >10MB | Leg 2a artifact |
| H2 | Spin abstracts WIT/wasi-http complexity with <5 lines of config | Legs 1a, 2b spin.toml |
| H3 | Native `spin up` cold start is <100ms | Legs 1a, 2b |
| H4 | Podman container overhead adds <200ms to cold start | 1b vs 1a, 2c vs 2b |
| H5 | Rust .wasm is smallest artifact and fastest cold start | Leg 3 vs all |
| H6 | Spin Python uses componentize-py under the hood (same .wasm size as 2a) | 2a vs 2b artifact |

## Metrics

| Metric | How measured |
|--------|--------------|
| Source size | `wc -c <source file>` |
| .wasm artifact size | file size after build |
| Build time (ms) | wall-clock time from source → .wasm |
| Cold start (ms) | `cold_start_ms` from `lib/bench.sh` |
| Memory RSS (MB) | `rss_mb` from `lib/bench.sh` |
| Warm latency p50/p95 | `hey -n 1000 -c 1` |
| Requests/sec | from `hey` output |

## Results

<!-- populated by benchmark.sh -->

| Metric | 1a JS/Spin native | 1b JS/Spin podman | 2a Py/raw wasmtime | 2b Py/Spin native | 2c Py/Spin podman | 3 Rust baseline |
|--------|---|---|---|---|---|---|
| Source size | | | | | | |
| Artifact (.wasm) | | | | | | |
| Build time (ms) | | | | | | |
| Runtime/image | | | | | | |
| Cold start (ms) | | | | | | |
| Memory RSS (MB) | | | | | | |
| hey p50 (ms) | | | | | | |
| hey p95 (ms) | | | | | | |
| hey req/s | | | | | | |

## Usage

```bash
# Install toolchains (once)
make deps

# Compile all sources to .wasm
make build

# Run full 6-leg benchmark
make bench

# Quick benchmark (10 requests)
make bench-quick

# Run BATS tests (requires running legs or skips gracefully)
make test
```

## Prerequisites

- `brew install fermyon/tap/spin wasmtime hey`
- `pip install componentize-py`
- Podman machine running for legs 1b and 2c (`podman machine start`)
- Rust with `wasm32-wasip2` target: `rustup target add wasm32-wasip2`

## Structure

```
003_wasm_compile/
├── README.md
├── benchmark.sh        # 6-leg benchmark harness
├── Makefile            # build / test / bench / clean
├── Containerfile       # Spin-in-podman (build-arg parameterized)
├── .gitignore          # build/ and node_modules excluded
├── lib -> ../001_hello_world/lib   # shared bench helpers
├── tests/
│   └── test_003.bats   # validates JSON from each leg
├── js-spin/            # JS → WASM via Spin
│   ├── spin.toml
│   ├── package.json
│   └── src/index.js
├── python-raw/         # Python → WASM via componentize-py (raw WIT)
│   ├── wit/proxy.wit
│   └── app.py
├── python-spin/        # Python → WASM via Spin
│   ├── spin.toml
│   └── app.py
└── rust/ -> ../001_hello_world/leg3_wasmtime   # Rust baseline
```

`.wasm` artifacts are gitignored (`build/`, `target/`, `*.wasm` in component dirs).
