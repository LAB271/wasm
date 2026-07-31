# Experiment 013 — Unicode Strategies

A 2×2 matrix comparing Unicode handling approaches in WASM:

|                   | **Server-side tables** | **Host delegation (JS)** |
|-------------------|------------------------|--------------------------|
| **With Unicode**  | Leg 1: embedded tables | Leg 2: import from host  |
| **ASCII-only**    | Leg 3: ASCII fallback  | Leg 4: ASCII (no imports)|

## Motivation

Unicode support in WASM is expensive. A full Unicode case-mapping table (for
`to_upper`/`to_lower`) adds 50-150KB to a `.wasm` binary. This experiment
measures the trade-offs between:

1. **Embedded tables** — self-contained, portable, large
2. **Host delegation** — smaller WASM, requires JS glue, browser-only
3. **ASCII fallback** — tiny, limited functionality

## Structure

```
013_unicode_strategies/
├── unicode-lib/            # Shared Rust string library
│   ├── Cargo.toml
│   └── src/lib.rs
├── legs/
│   ├── leg1_embedded/      # Full Unicode tables in WASM
│   ├── leg2_host_js/       # Delegate to JS TextEncoder/Intl
│   ├── leg3_ascii_only/    # ASCII-only fallback
│   └── leg4_ascii_no_import/ # ASCII, no host imports
├── host/                   # JS host for leg2
│   ├── unicode_bridge.js
│   └── test.html
├── build.sh
├── benchmark.sh
└── README.md
```

## Hypotheses

| # | Hypothesis | Status |
|---|-----------|--------|
| H1 | **Embedded Unicode** adds 50-150KB to .wasm size | — |
| H2 | **Host delegation** keeps WASM under 20KB for string ops | — |
| H3 | **ASCII fallback** is smallest (<5KB for string module) | — |
| H4 | **Runtime perf** is comparable — host calls add <1μs/op | — |
| H5 | **Host delegation** works in browser, fails in WASI CLI | — |

## Implementation Details

### Leg 1: Embedded Unicode Tables

Uses the `unicode-case` or `unicode-normalization` crate. All case mappings,
character properties, and normalization tables compiled into the WASM binary.

```rust
// In WASM — uses embedded tables
pub fn to_upper(s: &str) -> String {
    s.chars().map(|c| c.to_uppercase()).flatten().collect()
}
```

### Leg 2: Host Delegation (JS)

WASM imports host functions for Unicode operations. The JS host uses native
`String.prototype.toUpperCase()` and `Intl.Segmenter`.

```rust
// In WASM — imports from host
extern "C" {
    fn _host_to_upper(ptr: *const u8, len: usize, out: *mut u8) -> usize;
}

pub fn to_upper(s: &str) -> String {
    let mut buf = vec![0u8; s.len() * 4]; // UTF-8 can expand
    let len = unsafe { _host_to_upper(s.as_ptr(), s.len(), buf.as_mut_ptr()) };
    buf.truncate(len);
    String::from_utf8(buf).unwrap()
}
```

```javascript
// In host (JS)
const imports = {
    env: {
        _host_to_upper(ptr, len, outPtr) {
            const str = readString(ptr, len);
            const upper = str.toUpperCase();
            return writeString(outPtr, upper);
        }
    }
};
```

### Leg 3: ASCII-Only

No Unicode tables. Operations only work on ASCII range (0x00-0x7F). Non-ASCII
bytes pass through unchanged.

```rust
pub fn to_upper(s: &str) -> String {
    s.bytes().map(|b| {
        if b >= b'a' && b <= b'z' { b - 32 } else { b }
    }).map(|b| b as char).collect()
}
```

### Leg 4: ASCII, No Imports

Same as Leg 3 but compiled without any host imports. Tests the baseline size
of a pure-compute WASM module.

## Test Cases

Each leg runs the same test suite:

```rust
assert_eq!(to_upper("hello"), "HELLO");           // ASCII
assert_eq!(to_upper("café"), "CAFÉ");             // Latin-1 Extended
assert_eq!(to_upper("naïve"), "NAÏVE");           // Diacritics
assert_eq!(to_upper("Größe"), "GRÖSSE");          // German sharp s → SS
assert_eq!(to_upper("σ"), "Σ");                   // Greek
assert_eq!(to_upper("и"), "И");                   // Cyrillic

// Character iteration
assert_eq!(char_count("hello"), 5);
assert_eq!(char_count("héllo"), 5);               // 6 bytes, 5 chars
assert_eq!(char_count("日本語"), 3);               // 9 bytes, 3 chars
assert_eq!(char_count("👨‍👩‍👧"), 1);                  // 18 bytes, 1 grapheme

// Whitespace detection
assert!(is_whitespace(' '));
assert!(is_whitespace('\u{00A0}'));               // Non-breaking space
assert!(is_whitespace('\u{3000}'));               // Ideographic space
```

Leg 3/4 will fail non-ASCII cases — that's expected and part of the comparison.

## Results

*Run `./benchmark.sh` to populate.*

### Size Comparison

| Leg | Strategy | .wasm size | gzip size | Unicode support |
|-----|----------|-----------|-----------|-----------------|
| 1 | Embedded tables | | | Full |
| 2 | Host delegation | | | Full (browser) |
| 3 | ASCII fallback | | | ASCII only |
| 4 | ASCII, no imports | | | ASCII only |

### Correctness Matrix

| Test case | Leg 1 | Leg 2 | Leg 3 | Leg 4 |
|-----------|-------|-------|-------|-------|
| ASCII to_upper | ✓ | ✓ | ✓ | ✓ |
| Latin-1 to_upper | ✓ | ✓ | ✗ | ✗ |
| German ß → SS | ✓ | ✓ | ✗ | ✗ |
| Greek/Cyrillic | ✓ | ✓ | ✗ | ✗ |
| Grapheme count | ✓ | ✓ | ✗ | ✗ |

### Performance (μs/op)

| Operation | Leg 1 | Leg 2 | Leg 3 | Leg 4 |
|-----------|-------|-------|-------|-------|
| to_upper (10 chars) | | | | |
| char_count (100 chars) | | | | |
| is_whitespace (1 char) | | | | |

## Running

```bash
# Build all legs
./build.sh

# Run size + correctness benchmark
./benchmark.sh

# Test leg 2 in browser
cd host && python3 -m http.server 8080
# Open http://localhost:8080/test.html
```

## Prerequisites

```bash
rustup target add wasm32-wasip1
rustup target add wasm32-unknown-unknown  # for browser leg
cargo install wasm-opt
```

## Conclusions

*To be filled after running benchmarks.*

The recommended strategy depends on:
- **Portability requirement**: If WASI CLI support is needed, Leg 1 or Leg 3
- **Size budget**: If <20KB is required, Leg 2 or Leg 3/4
- **Unicode requirement**: If full i18n is needed, Leg 1 or Leg 2
- **Browser-only**: Leg 2 is optimal (small + full Unicode via host)
