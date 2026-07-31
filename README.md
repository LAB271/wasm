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
| [001](experiments/001_hello_world/) | hello_world | results pending | Flask/Docker vs Pyodide/Chromium vs Wasmtime — cold start, memory, throughput |
| [002](experiments/002_chromium_sandbox/) | chromium_sandbox | done | Chromium+Pyodide isolation strategies — worker pools, BrowserContext pooling, JS↔WASM bridge overhead |
| [003](experiments/003_wasm_compile/) | wasm_compile | results pending | Compiling JS/Python/Rust to `.wasm` via Spin/componentize-py/cargo, native vs. podman |
| [004](experiments/004_static_wasi_hello/) | static_wasi_hello | done | Static HTML page, zero server at execution time — `mvl-lang/mvl-playground`'s actual architecture |
| [005](experiments/005_stdout_capture_load/) | stdout_capture_load | done | stdout/stderr capture correctness + overhead at 10/1,000/100,000 lines |
| [006](experiments/006_worker_kill_switch/) | worker_kill_switch | done | `Worker.terminate()` against a genuine infinite loop — is it actually instant? (No — ~2.1s) |
| [007](experiments/007_custom_runtime_vs_interpreter/) | custom_runtime_vs_interpreter | done | Hand-written 78-line JS runtime shim vs. componentize-py vs. Pyodide — artifact size, cold start, build complexity |
| [008](experiments/008_mvl_example_wasm_harness/) | mvl_example_wasm_harness | done | Standalone (non-browser) host for `mvl build --backend=wasm` output — found a new actor-routing crash in `actor_trading` (mvl-lang/mvl#2083) |
| [009](experiments/009_rust_native_host/) | rust_native_host | done | Native Rust host embedding `wasmtime` directly, no HTTP — checks a Medium article's "200µs" claim against true cold start and against its own methodology |

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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

Please report vulnerabilities privately, not as a GitHub issue. See
[SECURITY.md](SECURITY.md).

## License

Copyright 2026 Schuberg Philis B.V.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
these files except in compliance with the License. You may obtain a copy of the
License in [LICENSE](LICENSE) or at <https://www.apache.org/licenses/LICENSE-2.0>.

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.
