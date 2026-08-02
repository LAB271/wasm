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
| [001](experiments/001_hello_world/) | hello_world | done | Flask/Docker vs Pyodide/Chromium vs Wasmtime — cold start, memory, throughput |
| [002](experiments/002_chromium_sandbox/) | chromium_sandbox | done | Chromium+Pyodide isolation — worker pools, BrowserContext pooling |
| [003](experiments/003_wasm_compile/) | wasm_compile | done | Compiling JS/Python/Rust to `.wasm` via Spin/componentize-py/cargo |
| [004](experiments/004_static_wasi_hello/) | static_wasi_hello | done | Static HTML page, zero server at execution time |
| [005](experiments/005_stdout_capture_load/) | stdout_capture_load | done | stdout/stderr capture correctness at scale |
| [006](experiments/006_worker_kill_switch/) | worker_kill_switch | done | `Worker.terminate()` latency against infinite loops |
| [007](experiments/007_custom_runtime_vs_interpreter/) | custom_runtime_vs_interpreter | done | Custom JS runtime vs componentize-py vs Pyodide |
| [008](experiments/008_mvl_example_wasm_harness/) | mvl_example_wasm_harness | done | Standalone WASM host for MVL compiler output |
| [009](experiments/009_rust_native_host/) | rust_native_host | done | Native Rust host embedding wasmtime directly |
| [010](experiments/010_mastermind_web/) | mastermind_web | done | Browser WASM: Rust + AssemblyScript engines |
| [011](experiments/011_mastermind_cli_wasi/) | mastermind_cli_wasi | done | CLI WASM with real WASI stdin/stdout |
| [012](experiments/012_stdlib_size_matrix/) | stdlib_size_matrix | done | Stdlib feature impact on binary size |
| [013](experiments/013_unicode_strategies/) | unicode_strategies | done | Unicode handling: embed vs delegate to host |
| [014](experiments/014_wasm_webserver/) | wasm_webserver | done | TCP vs serverless: guest-owned vs host-owned sockets |
| [015](experiments/015_postgres_bridge/) | postgres_bridge | done | Database access via host imports (no HTTP sidecar) |
| [016](experiments/016_ffi_assemblyscript/) | ffi_assemblyscript | done | FFI overhead: AssemblyScript calling Rust host |

---

## Key Learnings

### 1. Deployment Architectures

**Client-side (browser)**
- WASM runs in browser via `WebAssembly.instantiate()` — no server round-trips after initial load
- Ideal for compute-heavy UI (games, codecs, crypto) where latency matters
- Example: [010](experiments/010_mastermind_web/) — Mastermind scoring in 950-byte WASM
- Loading strategy: `fetch()` the binary, or base64-inline it into a JS module
  to dodge CORS/MIME/`file://` issues — see 010's fetch-vs-inline measurements

**Server-side (wasmtime)**
- Embed wasmtime as a library — single process, no container overhead
- Cold start: ~40ms (vs 500ms+ for containers)
- Example: [009](experiments/009_rust_native_host/) — native Rust host

**Serverless (Spin/Cloudflare Workers)**
- Host owns the socket, guest only handles requests
- Fastest cold start: host pre-warms the listener
- Example: [014](experiments/014_wasm_webserver/) — Spin vs raw TCP

| Architecture | Cold Start | Memory | When to use |
|--------------|------------|--------|-------------|
| Browser | 0 (cached) | 20MB | Interactive UI, offline-capable |
| wasmtime embed | ~40ms | ~20MB | Latency-sensitive, single-tenant |
| Serverless (Spin) | ~5ms | ~10MB | HTTP workloads, multi-tenant |
| Container | 500ms+ | 50MB+ | Legacy, complex dependencies |

### 2. WASM Targets

| Target | Type | Use case | Size optimization |
|--------|------|----------|-------------------|
| `wasm32-unknown-unknown` | Core module | Browser, no WASI | `wasm-opt -Oz` (60-70% reduction) |
| `wasm32-wasip1` | Core module | CLI, stdin/stdout | `wasm-opt -Oz --enable-bulk-memory` |
| `wasm32-wasip2` | Component | Sockets, HTTP, serverless | `wasm-tools strip` (~10% reduction) |

**Key insight:** Components are the future (composable, typed interfaces), but Binaryen
doesn't support them yet — use `wasm-tools strip` instead of `wasm-opt`.

### 3. Host Bridging Patterns

Three ways to extend WASM capabilities:

| Pattern | Latency | Complexity | Use case |
|---------|---------|------------|----------|
| **Host imports** | ~5ns/call | Moderate | Crypto, compression, DB |
| **HTTP sidecar** | ~2ms/call | Simple | Polyglot, legacy |
| **Embedded in host** | 0 | High | Tight integration |

**Experiment 015** showed host imports are essentially free (5ns overhead). For database
access, eliminating the HTTP sidecar reduced latency from 2ms to 460μs — 4x improvement.

**Experiment 016** demonstrated FFI overhead is negligible:
- Pure FFI call: 5ns
- SHA256 (1KB) via host: 764ns (vs ~50μs in pure WASM)
- Hardware crypto (SHA-NI, AES-NI) makes host-side 50-100x faster

### 4. Binary Size Optimization

For trivial functions, optimization is dramatic (16KB → 950B). For real applications,
gains are modest but worthwhile.

**Rust-side (all targets):**
```toml
[profile.release]
opt-level = "z"    # size
lto = true         # link-time optimization
panic = "abort"    # no unwinding
strip = true       # symbols
```

**Post-process:**
```bash
# Core modules
wasm-opt -Oz input.wasm -o output.wasm

# Components (wasip2)
wasm-tools strip input.wasm -o output.wasm
```

**HTTP compression:** WASM compresses extremely well (60-70% with brotli).
Pre-compress and serve with `Content-Encoding: br`.

| Experiment | Raw | Brotli | Savings |
|------------|-----|--------|---------|
| 010 Rust engine | 950B | 634B | 33% |
| 010 AS engine | 481B | 268B | 44% |
| 014 Leg A (TCP+SQLite) | 1.1MB | 448KB | 61% |
| 014 Leg B (Spin) | 222KB | 81KB | 64% |

### 5. Language Comparison

| Language | Strength | Weakness | Best for |
|----------|----------|----------|----------|
| **Rust** | Full control, `no_std`, fast | Verbose, compile time | Performance-critical |
| **AssemblyScript** | Tiny binaries, WASM-native | Limited stdlib | Simple compute |
| **Python (Pyodide)** | Ecosystem, rapid dev | 5s+ cold start, 300MB+ | Prototyping only |

AssemblyScript produces smaller binaries for trivial functions (481B vs 950B) because
it compiles directly through Binaryen. For complex applications, the difference narrows.

**Experiment 002 (legs 5a/5b)** shows Pyodide's cold-start/memory cost is Pyodide-specific, not
inherent to WASM-in-a-browser: native Rust/AssemblyScript WASM cut cold start ~2.9x (1.8s→0.6s)
and memory ~1.6x (602MB→375MB) versus Pyodide for identical CPU-bound work in the same harness.

### 6. WASI Capabilities

| Feature | wasip1 | wasip2 |
|---------|--------|--------|
| stdin/stdout | ✓ | ✓ |
| Filesystem | ✓ | ✓ |
| Environment vars | ✓ | ✓ |
| Sockets | ✗ | ✓ |
| HTTP | ✗ | ✓ |
| Clocks | ✓ | ✓ |

**Experiment 011** proved genuine interactive I/O works under wasip1. The gap in MVL's
WASM backend is implementation-specific, not a WASI limitation.

### 7. Database Access

| Approach | Latency | Size impact | When to use |
|----------|---------|-------------|-------------|
| Embedded SQLite | ~1ms | +1MB | Single-tenant, ACID needed |
| Host bridge (Postgres) | ~460μs | ~400B guest | External DB, connection pooling |
| Spin KV store | ~1ms | 0 | Serverless, simple K/V |

**Experiment 014** showed embedded SQLite works in WASM (requires WASI SDK for C compilation).
**Experiment 015** showed host imports beat HTTP sidecars by 4x for database access.

---

## Structure

```
experiments/
└── NNN_name/        # Self-contained experiment
    ├── README.md    # Hypotheses, methodology, results
    ├── Makefile     # build, test, benchmark, size targets
    └── leg*/        # One directory per variant under test
install.sh           # Check and install prerequisites
```

## Prerequisites

Run `./install.sh` to verify your environment.

| Tool | Purpose | Install |
|------|---------|---------|
| **podman** or docker | Container runtime | `brew install podman` |
| **wasmtime** | WASM runtime | `brew install wasmtime` |
| **rustup** + targets | Compile Rust to WASM | `rustup target add wasm32-wasip2` |
| **wasm-opt** | Binary optimizer | `brew install binaryen` |
| **wasm-tools** | Component tools | `cargo install wasm-tools` |
| **node** / npm | JS tooling | `brew install node` |
| **hey** | HTTP benchmark | `brew install hey` |

## License

Copyright 2026 Schuberg Philis B.V. — Apache License 2.0. See [LICENSE](LICENSE).
