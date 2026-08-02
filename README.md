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
| [008](experiments/008_mvl_example_wasm_harness/) | mvl_example_wasm_harness | done | Standalone (non-browser) host for `mvl build --backend=wasm` output — found and fixed 3 real memory/tag bugs in the ported runtime, one of which was mislabeled as a compiler bug (mvl-lang/mvl#2083, corrected and closed) |
| [009](experiments/009_rust_native_host/) | rust_native_host | done | Native Rust host embedding `wasmtime` directly, no HTTP — checks a Medium article's "200µs" claim against true cold start and against its own methodology |
| [010](experiments/010_mastermind_web/) | mastermind_web | done | Mastermind scored entirely by a compiled `.wasm` module, click-driven UI — reverse-engineered the struct-return ABI, worked around a dead-code-elimination bug dropping string data for unreached `pub` functions |
| [011](experiments/011_mastermind_cli_wasi/) | mastermind_cli_wasi | done | Same game, pure Rust, `wasm32-wasip1`, real WASI `fd_read` stdin — proves genuine interactive I/O works under WASM/WASI, isolating that MVL's `--backend=wasm` gap is backend-specific, not a WASM/WASI limitation |
| [012](experiments/012_stdlib_size_matrix/) | stdlib_size_matrix | done | Measure artifact size across stdlib feature combinations |
| [013](experiments/013_unicode_strategies/) | unicode_strategies | done | Compare Unicode handling strategies for WASM string runtime |
| [014](experiments/014_wasm_webserver/) | wasm_webserver | in progress | TCP vs serverless web server: guest-owned sockets (wasi:sockets) vs host-owned (Spin wasi:http) |

## Key Learnings

### WASM Binary Size Optimization

For browser/edge WASM, binary size directly impacts cold start and download time.
This section consolidates learnings from experiments 010-014.

#### The Two Toolchains

WASM optimization happens in two stages with different tools:

| Stage | Toolchain | What it does | Works on |
|-------|-----------|--------------|----------|
| **Compile-time** | Rust/LLVM | LTO, dead code elimination, symbol stripping | All targets |
| **Post-process** | Binaryen (`wasm-opt`) | WASM-native instruction combining, stack optimization | Core modules only |

**Why both matter:** Rust compiles via LLVM, a general-purpose backend. LLVM targets
WASM but doesn't understand it deeply. Binaryen is WASM-native — it sees optimization
opportunities LLVM misses. On trivial functions, Binaryen alone provides 60-70% reduction.

#### WASM Targets: Modules vs Components

| Target | Type | `wasm-opt` | Use case |
|--------|------|------------|----------|
| `wasm32-unknown-unknown` | Core module | ✓ Full support | Browser, embedded, no WASI |
| `wasm32-wasip1` | Core module | ✓ With `--enable-bulk-memory` | WASI preview 1 (stdin/stdout) |
| `wasm32-wasip2` | Component | ✗ Not supported | WASI preview 2 (sockets, HTTP) |

Components are the future of WASM (composable, typed interfaces), but Binaryen doesn't
support them yet — see [binaryen#6728](https://github.com/WebAssembly/binaryen/issues/6728).

#### Optimization Techniques by Target

**Core modules (`wasm32-unknown-unknown`, `wasm32-wasip1`):**

```toml
# Cargo.toml
[profile.release]
opt-level = "z"    # optimize for size
lto = true         # link-time optimization
panic = "abort"    # no unwinding
strip = true       # strip symbols
```

```bash
# Post-process (for wasip1, add --enable-bulk-memory)
wasm-opt -Oz input.wasm -o output.wasm
```

**Components (`wasm32-wasip2`):**

```toml
# Cargo.toml — same Rust-side optimizations
[profile.release]
opt-level = "z"
lto = true
strip = true
```

```bash
# wasm-tools strip removes custom sections (DWARF, etc.)
wasm-tools strip input.wasm -o output.wasm
```

#### Results by Experiment

| Exp | Target | Before | After Rust | After Tools | Reduction |
|-----|--------|--------|------------|-------------|-----------|
| 010 | `unknown-unknown` | 16 KB | 3.1 KB | **950 B** | 94% |
| 011 | `wasip1` | 89 KB | 61 KB | **53 KB** | 40% |
| 012 | `unknown-unknown` | varies | — | varies | (matrix) |
| 013 | `unknown-unknown` | varies | — | 3-5 KB | (matrix) |
| 014 | `wasip2` | 164 KB | 164 KB | **148 KB** | 10% |

**Key insight:** For trivial functions without `std` (010), optimization is dramatic.
For real applications with `std` (011, 014), gains are modest but still worthwhile.

#### Other Binaryen Tools

| Tool | Purpose | Component support |
|------|---------|-------------------|
| `wasm-opt` | Optimize/shrink | ✗ Core modules only |
| `wasm-merge` | Merge multiple modules | ✗ Core modules only |
| `wasm-metadce` | Dead code elimination with dependency info | ✗ Core modules only |

#### wasm-tools (Component-aware)

| Tool | Purpose |
|------|---------|
| `wasm-tools strip` | Remove custom sections (DWARF, names) |
| `wasm-tools component new` | Wrap core module as component |
| `wasm-tools component link` | Link dynamic library modules |

#### When to Use What

| Scenario | Target | Optimization |
|----------|--------|--------------|
| Browser app, no WASI | `wasm32-unknown-unknown` | Rust + `wasm-opt -Oz` |
| CLI tool, stdin/stdout | `wasm32-wasip1` | Rust + `wasm-opt -Oz --enable-bulk-memory` |
| Server, sockets/HTTP | `wasm32-wasip2` | Rust + `wasm-tools strip` |
| Edge/serverless (Spin, etc.) | `wasm32-wasip2` | Rust + `wasm-tools strip` |

#### AssemblyScript Note

AssemblyScript compiles directly through Binaryen (no LLVM intermediate), which is
why it produces smaller binaries for trivial functions (481B vs 950B for the same
`score_guess` function in experiment 010). For complex applications, the difference
narrows as actual code dominates overhead.

See individual experiment READMEs for detailed methodology:
- [010_mastermind_web](experiments/010_mastermind_web/README.md) — browser, core module, `#![no_std]`
- [011_mastermind_cli_wasi](experiments/011_mastermind_cli_wasi/README.md) — CLI, wasip1, bulk-memory
- [014_wasm_webserver](experiments/014_wasm_webserver/README.md) — server, wasip2, components

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
