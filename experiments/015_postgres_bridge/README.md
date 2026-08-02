# Experiment 015 — WASM to External Postgres via Pure Rust Host Bridge

Connect a WASM module to a real Postgres database running in Podman. Explores
the "host bridge" pattern where WASM calls out to host-provided database functions.

## Comparison with Experiment 001 Leg 4c

Experiment 001 already explored WASM→Postgres, but used a **Node.js sidecar**:

```
001/leg4c (Node.js sidecar):
┌─────────────┐  HTTP   ┌─────────────┐  pg wire  ┌─────────────┐
│ WASM Module │────────▶│  Node.js    │──────────▶│  Postgres   │
│ (wasmtime)  │  :3001  │  sidecar.js │           │  (container)│
└─────────────┘         └─────────────┘           └─────────────┘
     ↑                        ↑
     └── separate process ────┘
```

This experiment uses a **pure Rust host bridge** — no sidecar, no HTTP hop:

```
015 (Rust host imports):
┌─────────────┐  host   ┌─────────────┐  pg wire  ┌─────────────┐
│ WASM Module │────────▶│  Rust Host  │──────────▶│  Postgres   │
│ (wasmtime)  │ imports │  (embedded) │           │  (Podman)   │
└─────────────┘         └─────────────┘           └─────────────┘
     ↑                        ↑
     └── same process ────────┘
```

| Aspect | 001/leg4c (Node sidecar) | 015 (Rust host imports) |
|--------|--------------------------|-------------------------|
| IPC | HTTP over localhost | Direct function call |
| Latency | +1-2ms per query | <10μs per call |
| Processes | 2 (wasmtime + node) | 1 (wasmtime) |
| Complexity | Simple (HTTP is universal) | Moderate (define WIT interface) |
| Connection pool | In Node.js | In Rust host |
| Serialization | JSON over HTTP | Native WASM types |

## Hypothesis

- Eliminating HTTP hop reduces latency from ~2ms to <100μs per query
- Single process simplifies deployment and resource management
- Host imports are the "proper" way to extend WASM capabilities
- Worth the complexity for latency-sensitive workloads

## Approach

1. Run Postgres in Podman container
2. Define WIT interface for database operations
3. Implement host functions in Rust using `tokio-postgres`
4. Embed wasmtime with custom host imports
5. Benchmark vs 001/leg4c and 014 (embedded SQLite)

## Structure

```
015_postgres_bridge/
├── README.md
├── Makefile
├── wit/
│   └── database.wit      # Interface definition
├── host/
│   ├── Cargo.toml
│   └── src/main.rs       # Rust host with pg connection pool
└── guest/
    ├── Cargo.toml
    └── src/lib.rs        # WASM module using host imports
```

## WIT Interface (draft)

```wit
interface database {
    record row {
        id: u32,
        name: string,
        email: string,
        department: string,
    }

    query-all: func() -> list<row>;
    query-one: func(id: u32) -> option<row>;
    insert: func(name: string, email: string, dept: string) -> u32;
    update: func(id: u32, name: string, email: string, dept: string) -> bool;
    delete: func(id: u32) -> bool;
}
```

## Prerequisites

```bash
# Postgres in Podman
podman run -d --name postgres \
  -e POSTGRES_PASSWORD=secret \
  -p 5432:5432 \
  postgres:16-alpine

# Rust + wasmtime
rustup target add wasm32-wasip2
cargo install wasmtime-cli
```

## Status

✅ Working — CRUD test passes, benchmark complete.

## Results

**Benchmark: 1000 iterations of WASM → Host → Postgres COUNT(*) → WASM**

| Metric | Value |
|--------|-------|
| min | 360μs |
| median | **459μs** |
| avg | 462μs |
| p99 | 659μs |
| max | 1044μs |

**Comparison with 001/leg4c (Node.js sidecar):**

| Approach | Median latency | Processes |
|----------|---------------|-----------|
| 015 (Rust host imports) | ~460μs | 1 |
| 001/leg4c (HTTP sidecar) | ~2ms | 2 |

The ~4x improvement comes from eliminating:
- HTTP serialization/deserialization
- TCP loopback overhead
- Node.js event loop scheduling

**Guest WASM size:** 406 bytes (no_std, wasm-opt)

## Related

- Experiment 001 Leg 4c: Node.js sidecar approach (for comparison)
- Experiment 014: Embedded SQLite in WASM (no external DB)
- Experiment 009: Rust native host basics
