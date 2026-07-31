# Experiment 012 — Stdlib Size Matrix

Measures how different WASM optimization strategies affect binary size when a
small application calls into a larger stdlib library.

## Motivation

WASM binaries carrying a full stdlib can grow large. This experiment explores
the size trade-offs between:

1. **Link-time optimization (LTO)** — whole-program dead code elimination
2. **wasm-opt -Oz** — Binaryen's size-focused optimizer
3. **wasm-merge** — multi-module linking for deferred/lazy stdlib loading
4. **Feature flags** — compile-time stdlib subsetting (only include what you use)

## Structure

```
012_stdlib_size_matrix/
├── app/                    # Small Rust program (Mastermind-inspired)
│   ├── Cargo.toml
│   └── src/lib.rs
├── stdlib/                 # Larger "stdlib" with many functions
│   ├── Cargo.toml
│   └── src/lib.rs
├── legs/
│   ├── leg1_baseline/      # No optimization
│   ├── leg2_lto/           # LTO only
│   ├── leg3_wasm_opt/      # wasm-opt -Oz only
│   ├── leg4_lto_wasm_opt/  # LTO + wasm-opt -Oz
│   ├── leg5_feature_flags/ # Feature-gated stdlib
│   └── leg6_wasm_merge/    # Split modules, merged at load time
├── build.sh                # Build all legs
├── benchmark.sh            # Measure sizes
└── README.md
```

## Hypotheses

| # | Hypothesis | Status |
|---|-----------|--------|
| H1 | **LTO alone** removes ~30-50% of dead stdlib code | — |
| H2 | **wasm-opt -Oz** adds another ~10-20% reduction on top of LTO | — |
| H3 | **Feature flags** give the smallest binary (only compile what's used) | — |
| H4 | **wasm-merge** defers stdlib loading but total download ≈ monolithic | — |

## The App

A simplified Mastermind scorer translated from MVL to Rust. Uses stdlib for:
- String manipulation (parsing guesses)
- Random number generation (secret code)
- List/Vec operations (scoring)
- Optional: Unicode string functions

```rust
// Pseudocode — actual impl in app/src/lib.rs
fn score_guess(secret: &[u8], guess: &[u8]) -> (u8, u8) {
    // blacks: exact matches, whites: color-only matches
}

fn parse_guess(input: &str) -> Option<Vec<u8>> {
    // Parse "1 2 3 4" into [1, 2, 3, 4]
}
```

## The Stdlib

A kitchen-sink library mimicking what a real stdlib might include. Large enough
that dead code elimination is meaningful:

- **strings**: len, concat, split, trim, to_upper, to_lower, find, substring
- **unicode**: char_at, chars, is_whitespace, is_alphanumeric, normalize
- **collections**: map, filter, fold, zip, flatten, sort, dedup, reverse
- **math**: sqrt, pow, log, sin, cos, tan, abs, min, max, clamp
- **random**: int_range, float, bytes, shuffle, choice
- **time**: now, sleep, format_iso8601
- **io**: (stubs) read_file, write_file, exists
- **json**: (stubs) parse, stringify

Feature flags control which modules are compiled:
- `full` — everything (default)
- `strings` — string ops only
- `unicode` — strings + unicode
- `collections` — vec/list ops
- `math` — numeric functions
- `all-no-unicode` — everything except unicode tables

## Results

*Run `./benchmark.sh` to populate.*

| Leg | Strategy | .wasm size | gzip size | Notes |
|-----|----------|-----------|-----------|-------|
| 1 | baseline (debug) | | | |
| 2 | release + LTO | | | |
| 3 | release + wasm-opt -Oz | | | |
| 4 | release + LTO + wasm-opt -Oz | | | |
| 5 | feature flags (strings only) | | | |
| 6 | wasm-merge (split modules) | | | |

## Running

```bash
# Build all legs
./build.sh

# Run size benchmark
./benchmark.sh

# Build specific leg
cd legs/leg2_lto && ./build.sh
```

## Prerequisites

```bash
rustup target add wasm32-wasip1
cargo install wasm-opt       # Binaryen
cargo install wasm-merge     # wasmtime tools (or build from source)
```
