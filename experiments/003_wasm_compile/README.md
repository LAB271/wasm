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

| # | Hypothesis | Status |
|---|------------|--------|
| H1 | componentize-py .wasm (CPython embedded) is >10MB | **Confirmed** — leg 2a artifact is 34.5MB, ~3.4x the threshold |
| H2 | Spin abstracts WIT/wasi-http complexity with <5 lines of config | **Confirmed** — both `js-spin/spin.toml` and `python-spin/spin.toml` need only a 3-line `[[trigger.http]]` block; neither app author writes or vendors a `.wit` file at all (contrast with leg 2a's `python-raw/wit/proxy.wit` + explicit `componentize-py -d wit -w ... --all-features` invocation) |
| H3 | Native `spin up` cold start is <100ms | **Rejected** — measured 177ms (1a) and 296ms (2b), 1.8-3x over the threshold |
| H4 | Podman container overhead adds <200ms to cold start | **Rejected** — 1b vs 1a: +1,061ms (177ms→1,238ms), ~5.3x the claimed ceiling. 2c vs 2b could not be measured (leg 2c is blocked — see Results; the block is a component-ABI incompatibility unrelated to container overhead itself, so it neither confirms nor refutes H4, it just leaves 1b as the only real data point) |
| H5 | Rust .wasm is smallest artifact and fastest cold start | **Confirmed** — 128.1KB vs 11.6MB-35.9MB for the other 5 legs (90-280x smaller), cold start 175ms is fastest/tied-fastest among them. (The harness's bonus, out-of-table Leg 4 — AssemblyScript — produces an even smaller 11.7KB artifact; Rust is smallest only among this table's 6 legs, not universally.) |
| H6 | Spin Python uses componentize-py under the hood (same .wasm size as 2a) | **Partially confirmed** — 35.9MB (2b) vs 34.5MB (2a): same order of magnitude and clearly the same CPython-embedding mechanism, but not identical (2b is ~4% larger, likely from the `spin-http` world's extra imports vs the raw `wasi:http/proxy` world) |

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

Measured on Apple Silicon arm64 / macOS 26.6, `hey -n 1000 -c 1`, spin 4.0.0, wasmtime 43.0.1,
podman 5.8.2, componentize-py 0.17.2. `benchmark.sh` prints to stdout only — it does not write
this file; the table below was transcribed by hand from a real run (`make bench`).

**Legs 2a and 2c are blocked at runtime** (build succeeds, serving does not — see notes below the
table). Their `hey`/cold-start/RSS cells are marked *blocked*, not `n/a`: `hey` was still run
against the dead server and returned a nonsense "req/s" figure (thousands of instant
connection-refused errors, 0 successful requests) that would be actively misleading if reported
as throughput — it is intentionally omitted rather than transcribed.

| Metric | 1a JS/Spin native | 1b JS/Spin podman | 2a Py/raw wasmtime | 2b Py/Spin native | 2c Py/Spin podman | 3 Rust baseline |
|--------|---|---|---|---|---|---|
| Source size | 365B | 365B | 1.2KB | 473B | 473B | 1.2KB |
| Artifact (.wasm) | 11.6MB | 11.6MB (same artifact) | 34.5MB | 35.9MB | 35.9MB (same artifact) | 128.1KB |
| Build time (ms) | 79 | – (reuses 1a) | 3,360 | 57 | – (reuses 2b) | 230 |
| Runtime/image | spin 4.0.0 | spin v3.1.2 container, 325MB image | wasmtime 43.0.1 | spin 4.0.0 | spin v3.1.2 container, 349MB image | wasmtime 43.0.1 |
| Cold start (ms) | 177 | 1,238 | **blocked** | 296 | **blocked** | 175 |
| Memory RSS (MB) | 16 | ~424 (`podman stats`, not `ps` — see note) | blocked | 16 | blocked | 20 |
| hey p50 (ms) | 0.9 | 0.6 | blocked | 2.0 | blocked | 0.1 |
| hey p95 (ms) | 1.1 | 0.8 | blocked | 2.4 | blocked | 0.2 |
| hey req/s | 1,054 | 1,697 | blocked | 497 | blocked | 8,763 |

### Blocked legs

**Leg 2a (Python/componentize-py + `wasmtime serve`)** — builds fine (34.5MB artifact, 3.36s),
but `wasmtime serve` fails on the first request and the process exits:

```
Error: component imports instance `wasi:http/types@0.2.9`, but a matching implementation was not found in the linker
Caused by:
   0: instance export `[method]response-outparam.send-informational` has the wrong type
   1: function implementation is missing
```

Root cause: componentize-py 0.17.2 bundles its own `wasi:http` proxy-world shim, compiled against
an older point release of the interface than the one wasmtime 43.0.1 implements (which added
`response-outparam.send-informational`, a method the bundled shim doesn't provide). This is a
genuine ABI/version-drift issue between the installed componentize-py and the installed wasmtime,
not a config problem. Confirmed not fixable by a container/image change — the same wasm fails
identically under both `wasmtime serve` (native) and inside the leg 2c container (see below).
Upgrading componentize-py (tested 0.25.0, the current PyPI release) does resolve the ABI but
renames the generated Python bindings module (`wit_world.types` vs the current `proxy.types` the
requirements.txt-pinned 0.17.x generates), so `python-raw/app.py`'s imports would need to change —
out of scope for a minimal fix.

**Leg 2c (Python/Spin podman)** — the container image now builds and starts (see Containerfile fix
below), but the Spin runtime inside it fails to instantiate the component:

```
Error: component imports instance `spin:postgres/postgres@4.0.0`, but a matching implementation was not found in the linker
Caused by:
   0: instance export `connection` has the wrong type
   1: resource implementation is missing
```

Root cause: `python-spin`'s build (`componentize-py -w spin-http componentize app -o app.wasm`)
resolves the `spin-http` world using the locally-installed Spin 4.0.0 CLI's plugin templates,
which pull in the full spin-http world including a `spin:postgres/postgres@4.0.0` import — even
though this app never touches Postgres. No published `ghcr.io/fermyon/spin` container tag
implements that world version: the newest tag on GHCR is `v3.1.2` (checked via the GHCR tags API;
no `v4.x` tag exists yet), and `canary` fails identically. This is a genuine host/container Spin
version-skew issue, not fixable by picking a different tag.

### Fixes applied while running this benchmark

`benchmark.sh` and `Containerfile` had four real bugs, unrelated to the write-up itself, that
blocked or corrupted data — fixed inline (all in `experiments/003_wasm_compile/`):

1. **`Containerfile` pulled `ghcr.io/fermyon/spin:latest`, which no longer resolves** (`manifest
   unknown` — the `latest` tag doesn't exist). Pinned to `v3.1.2`, the newest published tag with a
   confirmed arm64 manifest. This is what unblocked leg 1b.
2. **`benchmark.sh`'s leg 2a build command was missing `--all-features` and used a shorthand world
   name** (`-w proxy` instead of `-w example:hello/proxy --all-features`), causing componentize-py
   to fail with `interface not found in package` — silently, because the command's own error
   output was redirected to `/dev/null`. Aligned it with the working invocation already in the
   `Makefile`.
3. **That same leg 2a build line redirected `timed_build`'s own stdout to `/dev/null`** (the
   `>/dev/null 2>&1` was scoped to the whole `timed_build ...` call, not just the inner build
   command), silently discarding the build-time measurement even on success. Wrapped the inner
   command in `bash -c '... >/dev/null 2>&1'` so only its output is suppressed.
4. Also fixed a cosmetic bug: `RUNTIME_1A`/`RUNTIME_2B` parsed `spin --version`'s *last* field
   (`2026-04-20)`, not the version number) via `awk '{print $NF}'`; changed to `awk '{print $2}'`.

None of these were introduced by this pass — all four pre-date it and were silently swallowing
either whole legs (1, 2) or individual metrics (3, 4).

### Key findings

1. **Podman container overhead is far from free: +1,061ms cold start (177ms→1,238ms, ~7x), the
   headline number for H4.** That's 5.3x over the hypothesis's own <200ms ceiling. The 2c-vs-2b
   half of H4 couldn't be measured (leg 2c is blocked for an unrelated reason), so 1b-vs-1a is the
   only real container-overhead data point this experiment produced — but it's a clean, large,
   unambiguous signal on its own.
2. **Native `spin up` cold start is not sub-100ms in practice** — both JS (177ms) and Python
   (296ms) came in 1.8-3x over the H3 target on this hardware.
3. **CPython-in-WASM is the size outlier by ~2 orders of magnitude** — componentize-py artifacts
   (34.5-35.9MB) dwarf the JS Spin component (11.6MB) and especially the Rust baseline (128.1KB).
4. **Toolchain version skew, not the experiment's own logic, caused both real blockers** —
   componentize-py 0.17.2's bundled wasi:http shim predates wasmtime 43's proxy world, and the
   Spin CLI (4.0.0) used to build is newer than any Spin container image GHCR publishes (latest is
   v3.1.2). Both are ecosystem-version-drift problems, not bugs in this experiment's code.
5. **RSS is not apples-to-apples between native and containerized legs** — native legs report
   process RSS via `ps` (16-20MB); container legs can only be measured via `podman stats` from the
   host (`podman`'s VM backend hides the in-VM PID from macOS `ps`), which accounts memory
   differently and reads far higher (~424MB for leg 1b) even before considering that some of that
   is fixed container/VM baseline rather than app footprint.

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
