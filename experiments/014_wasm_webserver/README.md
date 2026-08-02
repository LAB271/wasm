# Experiment 014 — WASM Web Server: TCP vs Serverless

Compare two architectures for serving HTTP from WASM:

| Leg | Model | Runtime | Who owns the socket |
|-----|-------|---------|---------------------|
| A | Full TCP | wasmtime + wasi:sockets | Guest WASM module |
| B | Serverless | Spin / wasmtime serve | Host runtime |

Both legs serve the same payload: a CSV of records loaded into an in-memory
"database" at startup, exposed as JSON via `/records` and `/records/{id}`.

## Hypothesis

Leg B (serverless) will be:
- Simpler to implement (no socket management)
- Faster cold start (host pre-warms the listener)
- More portable (works on Spin, Cloudflare Workers, etc.)

Leg A (TCP) will be:
- More flexible (custom protocols, websockets, streaming)
- Required only when the host doesn't provide HTTP

## Phases

This experiment builds incrementally:

1. **Phase 1 (this PR):** Read-only, CSV → in-memory Vec, JSON responses
2. **Phase 2:** Replace Vec with rusqlite (embedded SQLite)
3. **Phase 3:** Add write operations (POST/PUT/DELETE)

## Structure

```
014_wasm_webserver/
├── README.md
├── Makefile           # `make leg-a`, `make leg-b`, `make benchmark`
├── data/
│   └── records.csv    # Shared test data
├── leg_a_tcp/
│   ├── Cargo.toml     # wasm32-wasip2 + wasi:sockets
│   └── src/main.rs    # Full TCP server in WASM
└── leg_b_serverless/
    ├── Cargo.toml     # wasm32-wasip2 + wasi:http
    ├── spin.toml      # Spin manifest
    └── src/lib.rs     # Request handler only
```

## Prerequisites

```bash
# Spin (for Leg B)
curl -fsSL https://developer.fermyon.com/downloads/install.sh | bash

# Rust WASM targets
rustup target add wasm32-wasip2

# wasmtime (for Leg A and as Spin's engine)
brew install wasmtime
```

## Usage

```bash
make leg-a       # Build and run Leg A (TCP server)
make leg-b       # Build and run Leg B (Spin serverless)
make benchmark   # Compare cold start, throughput, memory
make test        # Verify both legs return identical JSON
```

## Data Format

`data/records.csv`:
```csv
id,name,email,department
1,Alice,alice@example.com,Engineering
2,Bob,bob@example.com,Marketing
3,Carol,carol@example.com,Engineering
```

API:
- `GET /records` → `[{"id":1,"name":"Alice",...}, ...]`
- `GET /records/1` → `{"id":1,"name":"Alice",...}`
- `GET /health` → `{"status":"ok"}`

## Results

_Pending benchmarks._

## Size Optimization

Both legs use Rust-side optimizations in `Cargo.toml`:

```toml
[profile.release]
opt-level = "z"    # optimize for size
lto = true         # link-time optimization
strip = true       # strip symbols
```

**Binaryen/wasm-opt limitation:** These experiments use `wasm32-wasip2` which produces
WASM components. Binaryen's `wasm-opt` does not yet support components — only core
modules. See [binaryen#6728](https://github.com/WebAssembly/binaryen/issues/6728).

For core WASM modules (like experiment 010), `wasm-opt -Oz` typically reduces size
by 60-70% on top of Rust's LTO. Components will benefit when Binaryen adds support.

Run `make size` to see current artifact sizes with optimization status.

## Related

- MVL crud_api example: `~/wc/mvl-lang/examples/crud_api/`
- MVL WASM epic: mvl-lang/mvl#1571
- Spin documentation: https://developer.fermyon.com/spin/v2/
