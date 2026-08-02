# wasm-experiments

A collection of hands-on experiments exploring WebAssembly (WASM) both in the browser and
as an alternative to traditional container runtimes. Each experiment tests a concrete
hypothesis, measures real numbers, and documents what held up and what didn't.

## Two use cases, constantly conflated

Almost every argument about WebAssembly gets muddled because **WASM has two entirely
separate deployment stories**, and people cite evidence from one to make claims about the
other. Get this straight first; everything else in this repo depends on it.

### 1. WASM in the browser (client-side)

The module runs inside the user's browser, hosted by its JavaScript engine (V8, JSC,
SpiderMonkey). It is downloaded with the page and instantiated by JS.

- **The host already exists.** There is no server, no runtime to provision, nothing to
  deploy. The browser is the sandbox.
- **Containers are irrelevant here.** There is no container to replace. "WASM vs Docker"
  is a category error in this use case.
- **Why you'd use it:** near-native compute in the page, a language other than JavaScript,
  and bit-identical results across engines ([017](experiments/017_float_determinism/)).
- **Experiments:** [004](experiments/004_static_wasi_hello/),
  [006](experiments/006_worker_kill_switch/), [010](experiments/010_mastermind_web/),
  [020](experiments/020_js_vs_wasm_crossover/)

### 2. WASM server-side

The module runs on your infrastructure, hosted by a runtime *you* choose. This is where the
Docker comparison actually lives — and it splits three ways, which matters enormously
because the numbers differ by two orders of magnitude:

| | What hosts the module | Cold start | Experiments |
|---|---|---|---|
| **a. Embedded / CLI** | Your own process embeds wasmtime as a library; WASM is a sandboxed plugin | ~40 ms | [008](experiments/008_mvl_example_wasm_harness/), [009](experiments/009_rust_native_host/), [011](experiments/011_mastermind_cli_wasi/), [015](experiments/015_postgres_bridge/), [016](experiments/016_ffi_assemblyscript/) |
| **b. WASM runtime inside a container** | An OCI container runs Spin/wasmtime, which runs your module | **1,238 ms** | [003](experiments/003_wasm_compile/) legs 1b/2c |
| **c. WASM *as* the workload** | A serverless host or a containerd/crun shim runs the module directly — no Linux userspace | ~5 ms | [014](experiments/014_wasm_webserver/), [018](experiments/018_wasm_platforms/) |

**(b) is the trap.** Measured in [003](experiments/003_wasm_compile/): the same module cold-starts
in 177 ms under `spin up` natively and 1,238 ms wrapped in podman. The container tax of
**+1,061 ms is six times larger than the WASM runtime's entire startup**, and worse than the
plain Flask-in-Docker baseline it was supposed to beat. Putting WASM in a container discards
most of what WASM bought you. It only makes sense when you need OCI/Kubernetes orchestration
badly enough to pay for it.

**(c) is what "Docker is dying" actually refers to** — the container is eliminated, not merely
filled with something lighter.

One more trap worth naming: running a *browser* server-side to execute WASM (Playwright +
headless Chromium) inherits Chromium's own floor of ~600 ms and ~240 MB regardless of what
runs inside it — measured in [002](experiments/002_chromium_sandbox/), which is slower to cold
start than a container. Use case 1's host does not transplant into use case 2.

## Why

> "If WASM+WASI existed in 2008, we wouldn't have needed to created [sic] Docker. That's how
> important it is. Webassembly on the server is the future of computing. A standardized system
> interface was the missing link. Let's hope WASI is up to the task!"
>
> — Solomon Hykes, co-founder of Docker, [27 March 2019](https://twitter.com/solomonstre/status/1111004913222324225)

That quote launched a thousand "Docker is dead" posts. It is also almost always cited without
Hykes' own clarification, posted the same day:

> "'So will wasm replace Docker?' No, but imagine a future where Docker runs linux containers,
> windows containers and wasm containers side by side. Over time wasm might become the most
> popular container type. Docker will love them all equally, and run it all :)"
>
> — [Solomon Hykes, same thread](https://twitter.com/solomonstre/status/1111113329647325185)

Coexistence, not replacement — and that second prediction has aged better than the first.
[003](experiments/003_wasm_compile/) already runs a WASM runtime inside a container, and
`containerd` WASM shims make "wasm container type" a literal, shipping reality.

The premise these experiments test: WASM runtimes can replace Docker containers for
serverless-style workloads — smaller artifacts, faster cold starts, lower memory. Each
experiment validates (or refutes) part of that claim with reproducible benchmarks on real
hardware.

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
| [017](experiments/017_float_determinism/) | float_determinism | done | Cross-engine float determinism: JS `Math.*` vs WASM libm, ULP-level |
| [018](experiments/018_wasm_platforms/) | wasm_platforms | done | Local-testability matrix across 4 container architectures (incl. verified podman+crun WASM-as-workload) and 4 platform runtimes; wasi-http portability demonstrated across 5 runtimes |
| [019](experiments/019_wasm_debugging/) | wasm_debugging | done | Debuggability vs binary size — DWARF/name-section cost across 4 tiers; the other side of 010 |
| [020](experiments/020_js_vs_wasm_crossover/) | js_vs_wasm_crossover | done | Where WASM stops paying: rematches 010's 1.68x to parity (JS formulation matters more than language — deopts, not branches); marshal-vs-compute across scalars/arrays/strings/objects; batching crossover at K≈4-16 |

### How to read these

Not every experiment is a rigorous benchmark, and that's deliberate. Each kind is held to a
different standard, so read the numbers accordingly:

| Kind | Examples | Standard it's held to |
|------|----------|----------------------|
| **Benchmark** | 001, 002, 003, 014, 015, 016, 020 | Real numbers, same-session fairness, hypotheses marked from measured data |
| **Mechanism explainer** | 010, 013, 019 | Show how it works; numbers are illustrative, the tradeoff is the deliverable |
| **Correctness probe** | 005, 011, 017 | Does it behave as specified? Bit-exact where it matters, not perf-focused |
| **Survey** | 018 | Verified-installable claims only; sources cited; what-I-ran kept separate from what-I-read |

A number from a mechanism explainer is there to make a tradeoff legible, not to be cited as a
performance result. A benchmark's numbers are meant to be argued with.

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

Measured cold starts, worst to best. See [Two use cases](#two-use-cases-constantly-conflated)
for why rows 1-2 and rows 3-6 answer different questions:

| Architecture | Cold Start | Memory | Source | When to use |
|--------------|------------|--------|--------|-------------|
| Browser, client-side | 0 (cached) | ~20MB | [010](experiments/010_mastermind_web/) | Interactive UI, offline-capable |
| Headless browser, server-side | ~620ms | ~375MB | [002](experiments/002_chromium_sandbox/) leg 5a | Essentially never — Chromium's floor dominates |
| Spin runtime in a container | **1,238ms** | ~424MB | [003](experiments/003_wasm_compile/) leg 1b | Only if you need OCI/k8s orchestration |
| Container running a normal process | 500ms+ | 50MB+ | [001](experiments/001_hello_world/) leg 1 | Legacy, complex dependencies |
| `spin up` native | 177ms | 16MB | [003](experiments/003_wasm_compile/) leg 1a | HTTP workloads without orchestration |
| wasmtime embedded as a library | ~40ms | ~20MB | [009](experiments/009_rust_native_host/) | Latency-sensitive, single-tenant |
| Serverless, host owns the socket | ~5ms | ~10MB | [014](experiments/014_wasm_webserver/) | HTTP workloads, multi-tenant |

Two results here are worth staring at. **Containerising the WASM runtime (1,238ms) is slower
than the plain container baseline it was meant to beat (500ms+)** — the WASM gains are entirely
consumed by the container tax. And **a headless browser used as a server-side runtime (~620ms)
is also slower than that baseline**, even after removing Pyodide and running native WASM.
Both are cases of keeping a heavyweight host and swapping only what runs inside it.

### 2. WASM Targets

| Target | Type | Use case | Size optimization |
|--------|------|----------|-------------------|
| `wasm32-unknown-unknown` | Core module | Browser, no WASI | `wasm-opt -Oz` (60-70% reduction) |
| `wasm32-wasip1` | Core module | CLI, stdin/stdout | `wasm-opt -Oz --enable-bulk-memory` |
| `wasm32-wasip2` | Component | Sockets, HTTP, serverless | `wasm-tools strip` (~10% reduction) |

**Key insight:** Components are the future (composable, typed interfaces), but Binaryen
doesn't support them yet — use `wasm-tools strip` instead of `wasm-opt`.

### 3. Float math: the instruction set is not your stdlib

The single most transferable gotcha found in this repo, because it silently costs both
size and speed and produces no warning. **WASM's float instruction set tracks IEEE-754's
own required/recommended split:**

- IEEE-754 §5 **requires** correctly-rounded `add`, `sub`, `mul`, `div`, **`sqrt`**,
  `remainder`, conversions — WASM has an instruction for each.
- IEEE-754 §9.2 lists `sin`, `cos`, `exp`, `log`, `pow` as **recommended**, i.e. optional
  — WASM has none of them.

"Does WASM have an instruction for this?" is nearly the same question as "does IEEE-754
require it?" Whatever it lacks, your guest must carry as code.

Measured, on `wasm32-unknown-unknown` ([020](experiments/020_js_vs_wasm_crossover/),
[017](experiments/017_float_determinism/)):

| Situation | Example | Consequence |
|-----------|---------|-------------|
| Instruction exists, your stdlib exposes it | `abs`, `min`, `max`, `copysign` | free — one opcode |
| **Instruction exists, your stdlib hides it** | Rust `no_std`: `sqrt`, `floor`, `ceil`, `trunc` | **9–15x slower**, software routine for a single opcode |
| Instruction exists, semantics differ | `round` (half-away-from-zero) vs `f64.nearest` (half-to-even) | compiler emits a helper, not the instruction |
| No instruction exists | `sin`, `cos`, `exp`, `log`, `pow` | must bundle libm: **+10.2 KB**, buys bit-identical results across engines |

Only the last row is a real trade. The second is pure waste — Rust's `core`/`std`
boundary is a packaging decision that predates its WASM backend and doesn't line up with
the instruction set, so a `no_std` build strands four instructions that are right there.

**If you generate or hand-write WASM,** map your math surface onto the instruction set
rather than onto another language's stdlib: lower `sqrt`/`floor`/`ceil`/`trunc`/`abs`/
`min`/`max`/`copysign` directly, verify semantics before lowering (`round` is the trap),
and bundle libm only for the genuinely absent set.

**Detect it in any build you already have** — look for the instruction you expect:

```bash
wasm-tools print module.wasm | grep -c 'f64.sqrt'
# 0 while calling sqrt => a software routine got linked in
```

### 4. Host Bridging Patterns

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

### 5. Binary Size Optimization

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

**Experiment 017** measured the flip side of size optimization: bundling a software
`libm` for deterministic trig (`sin`/`cos`/`tan`/`pow`/`exp`/`log`) instead of relying
on a host instruction costs 10.2KB on top of a 180B arith-only baseline — determinism
is bought with bytes, not free.

| Experiment | Raw | Brotli | Savings |
|------------|-----|--------|---------|
| 010 Rust engine | 950B | 634B | 33% |
| 010 AS engine | 481B | 268B | 44% |
| 014 Leg A (TCP+SQLite) | 1.1MB | 448KB | 61% |
| 014 Leg B (Spin) | 222KB | 81KB | 64% |

### 6. Language Comparison

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

### 7. WASI Capabilities

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

**Experiment 018** demonstrated the wasi-http convergence directly: one component built
once ran unmodified on Spin, raw `wasmtime serve`, and wasmCloud. Cloudflare Workers and
Fastly's Viceroy could not run it as-is — Workers because workerd/V8 only parses core Wasm
modules (not the Component Model's binary format at all), Viceroy because its Component
Model support is explicitly experimental. Portability is real but not universal yet.

### 8. Database Access

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
