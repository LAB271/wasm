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

1. **Phase 1:** ✅ Read-only, CSV → in-memory storage, JSON responses
2. **Phase 2:** ✅ Embedded SQLite via rusqlite (Leg A only)
3. **Phase 3:** ✅ Full CRUD operations (GET/POST/PUT/DELETE)
4. **Phase 4:** ⬚ Spin key-value store (Leg B persistence)

### Phase 4: Spin Key-Value Store

Spin provides a built-in key-value store that persists across requests. This
solves Leg B's statelessness without external infrastructure.

```rust
use spin_sdk::key_value::Store;

let store = Store::open_default()?;
store.set("key", b"value")?;
let data = store.get("key")?;
```

**Hypothesis:** Simple, zero-config persistence with ~1ms overhead per operation.

### Related Experiments

- **015:** External Postgres via Podman — host bridge pattern, real ACID
- **016:** FFI — AssemblyScript calling Rust host functions

---

### Phase 2: SQLite in WASM

Leg A uses **embedded SQLite** via `rusqlite` with the `bundled` feature. This
compiles SQLite from C source into the WASM module.

**Requirements:**
- WASI SDK installed at `/opt/wasi-sdk` (provides C compiler for wasm32-wasip2)
- Download from: https://github.com/WebAssembly/wasi-sdk/releases

**Size impact:**
- Without SQLite: ~148 KB
- With SQLite: ~1.1 MB

Leg B (serverless) still uses HashMap — in serverless model, state resets each
request anyway unless you use Spin's key-value store or an external database.

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
- `GET /health` → `{"status":"ok"}`
- `GET /records` → `[{"id":1,"name":"Alice",...}, ...]`
- `GET /records/:id` → `{"id":1,"name":"Alice",...}`
- `POST /records` → Create new record (body: `{"name":"...","email":"...","department":"..."}`)
- `PUT /records/:id` → Update existing record
- `DELETE /records/:id` → Delete record (returns 204 No Content)

Note: In Leg B (serverless), writes don't persist between requests unless
you use Spin's key-value store or an external database.

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

The build also runs `wasm-tools strip` to remove custom sections (DWARF debugging
info, names section) that aren't needed at runtime.

### HTTP Compression

WASM binaries compress extremely well. The build generates `.gz` (gzip) and `.br`
(brotli) pre-compressed versions for HTTP serving:

| Leg | Raw | Gzip | Brotli | Savings |
|-----|-----|------|--------|---------|
| A (TCP + SQLite) | 1.1 MB | 478 KB | **448 KB** | 61% |
| B (Spin serverless) | 222 KB | 88 KB | **81 KB** | 64% |

Brotli consistently beats gzip by ~5-10%. For WASM distribution:
- **CDN/static hosting**: serve pre-compressed `.br` files with `Content-Encoding: br`
- **Dynamic hosting**: enable brotli compression at the reverse proxy layer
- **Edge/serverless**: smaller = faster cold start (less to compile)

Run `make size` to see current artifact sizes.

### Why WASM compresses so well

WASM binaries have high redundancy:
- Repetitive instruction patterns (local.get, i32.add, call sequences)
- Long runs of zeros (function padding, data section alignment)
- Predictable structure (section headers, type indices)

This makes them ideal for dictionary-based compression (LZ77 family).

### Binaryen/wasm-opt limitation

These experiments use `wasm32-wasip2` which produces WASM components. Binaryen's
`wasm-opt` does not yet support components — only core modules.
See [binaryen#6728](https://github.com/WebAssembly/binaryen/issues/6728).

| Tool | Component support | Effect |
|------|-------------------|--------|
| `wasm-tools strip` | ✓ Yes | ~10% reduction (removes DWARF, names) |
| `wasm-opt -Oz` | ✗ No | Would be 60-70% on core modules |

For core WASM modules (like experiment 010), `wasm-opt -Oz` typically reduces size
by 60-70% on top of Rust's LTO. Components will benefit when Binaryen adds support.

## Related

- Spin documentation: https://developer.fermyon.com/spin/v2/
