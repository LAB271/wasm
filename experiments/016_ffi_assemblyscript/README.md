# Experiment 016 — FFI: AssemblyScript Calling Rust Host Functions

Explore the WASM↔Host FFI boundary by writing business logic in AssemblyScript
that calls external functions implemented in Rust on the host side.

## Comparison with Experiment 010

Experiment 010 has an AssemblyScript module (`engines/assemblyscript/`) but it's
**fully self-contained** — no host imports at all. The code explicitly avoids
array indexing to prevent pulling in the AS runtime's `abort` import:

```typescript
// 010: scalar counters to avoid any host imports
let sLeft0 = 0, sLeft1 = 0, sLeft2 = 0, ...
```

This experiment explores the **opposite**: deliberately using host imports to
offload work to Rust that WASM can't do efficiently (crypto, I/O, native libs).

```
010 (self-contained):           016 (host-dependent):
┌─────────────────┐             ┌─────────────────┐
│  AssemblyScript │             │  AssemblyScript │
│  (pure WASM)    │             │  (orchestrator) │
│  ─────────────  │             │  ─────────────  │
│  no imports     │             │  host_sha256()  │
│                 │             │  host_encrypt() │
│                 │             │  host_sign()    │
└─────────────────┘             └────────┬────────┘
                                         │ FFI
                                ┌────────▼────────┐
                                │   Rust Host     │
                                │  (ring, etc.)   │
                                └─────────────────┘
```

## Hypothesis

- FFI call overhead is negligible (<1μs per call for simple types)
- String/buffer passing has measurable but acceptable overhead (~10-100μs)
- Useful for providing capabilities WASM can't do efficiently:
  - **Cryptography** (host has hardware AES-NI, SHA extensions)
  - **Compression** (zstd, brotli native libs)
  - **Image processing** (SIMD on host)
  - **Regex** (complex Unicode handling)
- AssemblyScript is a good fit for "orchestration" code that calls host functions

## Approach

1. Write a Rust host runtime using wasmtime with custom imports
2. Define host functions:
   - `host_sha256(data: &[u8]) -> [u8; 32]`
   - `host_encrypt_aes(key: &[u8], data: &[u8]) -> Vec<u8>`
   - `host_compress_zstd(data: &[u8]) -> Vec<u8>`
3. Write AssemblyScript module that imports and calls these
4. Microbenchmark: FFI vs pure-WASM implementations
5. Measure overhead at different buffer sizes

## Structure

```
016_ffi_assemblyscript/
├── README.md
├── Makefile
├── host/                   # Rust host runtime
│   ├── Cargo.toml          # wasmtime, ring, zstd
│   └── src/main.rs         # Defines imports, runs guest
└── guest/                  # AssemblyScript module
    ├── package.json
    ├── asconfig.json
    └── assembly/
        ├── index.ts        # Main logic using host functions
        └── imports.ts      # Declare external host functions
```

## Expected Results

| Operation | Pure WASM | Host FFI | Speedup |
|-----------|-----------|----------|---------|
| SHA256 (1KB) | ~50μs | ~5μs | 10x |
| AES-256 (1KB) | ~100μs | ~2μs | 50x |
| zstd compress (10KB) | N/A | ~100μs | ∞ |

Hardware crypto instructions (AES-NI, SHA-NI) should dominate for crypto ops.

## Prerequisites

```bash
# AssemblyScript
npm install assemblyscript

# Rust + wasmtime
rustup target add wasm32-unknown-unknown
cargo install wasmtime-cli
```

## Status

⬚ Not started

## Related

- Experiment 009: Rust native host (wasmtime embedding basics)
- Experiment 010: Self-contained AssemblyScript (no host imports)
- Experiment 015: Host imports for database access
