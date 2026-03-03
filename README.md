# wasm-experiments

A collection of hands-on experiments exploring WebAssembly (WASM) as an alternative
to traditional container runtimes. Each experiment tests a concrete hypothesis, measures
real numbers, and documents what held up and what didn't.

## Why

The premise: WASM runtimes can replace Docker containers for serverless-style workloads —
smaller artifacts, faster cold starts, lower memory. These experiments validate (or refute)
that claim with reproducible benchmarks on real hardware.

Reference: [AWS's Stealth Container Killer](https://aws.plainenglish.io/awss-stealth-container-killer-we-replaced-docker-with-a-browser-and-slashed-costs-by-60-43fceea80b15)

## Experiments

| # | Name | Status | What it tests |
|---|------|--------|---------------|
| [001](experiments/001_hello_world/) | hello_world | planned | Flask/Docker vs Pyodide/Chromium vs Wasmtime — cold start, memory, throughput |

## Structure

```
experiments/
└── NNN_name/        # Self-contained experiment
    ├── README.md    # Hypotheses, methodology, results
    ├── benchmark.sh # Reproducible benchmark runner
    └── leg*/        # One directory per runtime under test
install.sh           # Check and install prerequisites
```

## Prerequisites

Run `./install.sh` to verify your environment. It checks all required tools and
auto-installs the Rust WASM target if `rustup` is present.

| Tool | Purpose | Install |
|------|---------|---------|
| **podman** _(preferred)_ or docker | Container runtime for Leg 1 | `brew install podman` |
| **wasmtime** | Native WASM runtime for Leg 3 | `brew install wasmtime` |
| **rustup** + wasm32-wasip2 | Compile Rust to WASM component | `brew install rustup && rustup-init` |
| **node** / npm | Puppeteer harness for Leg 2 | `brew install node` |
| **hey** | Warm benchmark (1000 req) | `brew install hey` |

### Container runtime note

Experiments use **Podman** (rootless, daemonless) by default. Docker works as a
drop-in if Podman is not available — `install.sh` detects whichever is running and
sets `CONTAINER_CMD` accordingly. Leg 1's `run.sh` respects this variable.

To start Podman on macOS:

```bash
brew install podman
podman machine init
podman machine start
```
