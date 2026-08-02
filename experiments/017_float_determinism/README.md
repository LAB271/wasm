# Experiment 017 — Float Determinism

Fact-checks a common claim (seen in a Medium article on WASM portability): "JavaScript
floats behave differently across engines — V8 on Android vs JavaScriptCore on iOS — so
compiling to WASM gives you identical results everywhere." That claim is half right.
This experiment measures exactly where the line is, in bits, not adjectives.

## The claim, precisely

- **Basic arithmetic** (`+ - * /`, `sqrt`) is strict IEEE-754 binary64 in both JS and
  WASM. There is no divergence to find — both specs mandate the exact same bits.
- **`Math.sin/cos/tan/pow/exp/log`** are explicitly **implementation-approximated** in
  ECMA-262 (the "implementation-approximated" term of art: a facility that "defers its
  definition to an external source while recommending an ideal behaviour" — conforming
  engines are free to choose any behavior within loose constraints). V8, JavaScriptCore,
  and SpiderMonkey are allowed to differ in the last ULP, and — as measured below —
  they do.
- **WASM has no transcendental instruction** — there is no `f64.sin` opcode in the
  spec. When Rust calls a sin/cos/pow/exp/log implementation, the compiler links a
  software implementation **into the .wasm module itself**. WASM's determinism for
  trig comes from *shipping your own math library*, not from any instruction-level
  guarantee that WASM provides for free.
- WASM has its own **documented** non-determinism (NaN bit patterns, relaxed-SIMD) —
  real, spec-sanctioned, and distinct from the divergence measured here. See
  "Known WASM non-determinism" below.

## Hypotheses

| # | Hypothesis | Result |
|---|-----------|--------|
| H1 | `Math.sin/cos/tan/pow/exp/log` are bit-identical across V8/JSC/SpiderMonkey | **Rejected** — sin/cos/tan/exp/log measurably diverge. `pow` happened to agree everywhere in our domain (see caveat below) |
| H2 | The same transcendentals via Rust→WASM are bit-identical across all hosts (node/jsc/spidermonkey/bun **and** wasmtime with no JS at all) | **Confirmed** — zero divergence across all 5 hosts, all 11 functions, all 300 samples each |
| H3 | Basic arithmetic (`+ - * /`, `sqrt`) is bit-identical in both JS and WASM everywhere | **Confirmed** (control) |
| H4 | WASM's determinism comes from a bundled libm, not an instruction guarantee | **Confirmed** — zero host math imports in the .wasm module; the trig-vs-arith-only size delta is the bundled implementation made visible (see below) |

## Methodology

**Bit patterns, never decimal strings.** Every comparison extracts the raw IEEE-754
bit pattern via `Float64Array` → `BigUint64Array` (JS) or `f64::to_bits()` (Rust).
`toString()`/`toFixed()`/`JSON.stringify` all round to fewer digits than a double
carries and would hide exactly the single-ULP differences this experiment hunts for.

**A distribution, not a boolean.** For each function: how many of 300 inputs differ
between two hosts, the max ULP delta among the differing ones, and an FNV-1a
fingerprint over all 300 result bit patterns (two hosts with the same fingerprint
agree on literally everything). ULP distance is computed by mapping each f64's bit
pattern to a monotonically-ordered unsigned 64-bit key (flip the sign bit for
positive floats, bitwise-NOT for negative floats — the standard trick for making
IEEE-754 bit patterns integer-comparable) and taking the absolute difference of the
two keys.

**Byte-identical inputs, generated independently on every host.** A from-scratch
xorshift32 PRNG (`rust/compute/src/lib.rs` and `js/battery.js`, mirrored operation for
operation) derives 300 f64 test inputs per function from a fixed seed, split across
four magnitude buckets (`1e-8`, `10`, `1e4`, `1e8`) with random sign. No input file is
shared between hosts — each of the 5 processes (node, jsc, `js`, bun, wasmtime)
independently regenerates the same sequence from the same seed. This only works
*because* basic arithmetic is bit-identical everywhere (H3) — the PRNG's own bit ops
and the bucket-scaling multiply are exactly-specified in both Rust and JS, so
independent regeneration is safe. `pow`'s exponent operand uses a separate ±10 range
(instead of the same magnitude buckets as its base) so results don't all saturate to
±Infinity/0.

## Architecture

```
017_float_determinism/
├── rust/
│   ├── compute/        # Shared PRNG + math functions (rlib, no_std-friendly)
│   ├── wasm-lib/        # cdylib, wasm32-unknown-unknown — loaded by JS hosts
│   └── wasm-driver/     # bin, wasm32-wasip1 — standalone battery runner for wasmtime
├── js/
│   ├── battery.js       # Runs on node/jsc/js(spidermonkey)/bun — JS row + WASM row
│   └── compare.js       # Parses all captured CSVs, prints the divergence matrix
├── output/               # Built .wasm artifacts (committed — see below)
├── build.sh
├── run_matrix.sh         # Runs the full matrix, prints the report
└── Makefile
```

`compute` is the single source of truth for the PRNG and math functions. It's compiled
twice into `wasm-lib` (once with the `trig` feature, once without — that's the H4 size
delta) and once into `wasm-driver`. `js/battery.js` mirrors the PRNG by hand (there's
no way to share code between Rust and 4 different JS shells with no common module
convention) — see the doc comments in both files for the exact correspondence.

### Why `libm` and not `f64::sin()`

The original plan was to call Rust's `f64::sin()`/`f64::cos()`/etc. directly and let
`std` pick whatever the target provides. That broke in a very on-topic way:

- On `wasm32-unknown-unknown`, calling `f64::sin()` compiles cleanly but **traps at
  runtime with `call stack exhausted`** — confirmed by running the module under
  `wasmtime run --invoke sin`. The linker resolves the "sin" symbol to a
  self-referential stub instead of a real implementation, because this bare target
  (no OS, no libc) doesn't provide one and nothing errors at link time.
- `wasm32-wasip1` **does** get a working transcendental for free, via wasi-libc's
  bundled musl-derived libm.

That's an asymmetry that would have confounded H2 itself: if the JS-facing module
(unknown-unknown) and the wasmtime-facing module (wasip1) silently used two *different*
libm implementations, a mismatch between them wouldn't tell you anything about WASM
determinism — it would just mean we linked two different math libraries. The fix: both
targets explicitly depend on the [`libm`](https://crates.io/crates/libm) crate (a pure-Rust,
`no_std`-compatible reimplementation) for every trig function, so the *same* algorithm,
not just "some libm or other," compiles into both wasm builds. This is directly what
H4 claims — the compiler links a software libm into the module — made unavoidable in
practice rather than just asserted.

## Results

Full matrix: `make matrix` (runs `./build.sh` then `./run_matrix.sh`). Below is the
actual captured output — 5 hosts, 11 functions, 300 samples/function, seed `0xC0FFEE`.

### Hosts

| Host | Engine | Notes |
|---|---|---|
| node v26.5.0 | V8 | |
| jsc | JavaScriptCore | `/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc`, ships with macOS |
| `js` (spidermonkey 140.12.0) | SpiderMonkey | `brew install spidermonkey` |
| bun 1.3.14 | JavaScriptCore | Bun embeds JSC, not V8 — see below, its results confirm this |
| wasmtime 43.0.1 | (no JS) | `wasmtime run` invoking the wasip1 driver directly; proves determinism isn't a browser/JS-embedding artifact |

All 5 were available and ran successfully; no host had to be skipped.

### JS row — `Math.*` (H1 / H3 control), reference = node/V8

| function | jsc (JavaScriptCore) | js (SpiderMonkey) | bun (JavaScriptCore) |
|---|---|---|---|
| add | identical | identical | identical |
| sub | identical | identical | identical |
| mul | identical | identical | identical |
| div | identical | identical | identical |
| sqrt | identical | identical | identical |
| **sin** | 11/300 (3.7%), max 1 ULP | 11/300 (3.7%), max 1 ULP | 11/300 (3.7%), max 1 ULP |
| **cos** | 11/300 (3.7%), max 1 ULP | 11/300 (3.7%), max 1 ULP | 11/300 (3.7%), max 1 ULP |
| **tan** | 91/300 (30.3%), max 2 ULP | 91/300 (30.3%), max 2 ULP | 91/300 (30.3%), max 2 ULP |
| pow | identical | identical | identical |
| **exp** | 12/300 (4.0%), max 1 ULP | identical | 12/300 (4.0%), max 1 ULP |
| **log** | 3/300 (1.0%), max 1 ULP + 153 NaN-payload diffs | identical (0 numeric diffs) + 153 NaN-payload diffs | 3/300 (1.0%), max 1 ULP + 153 NaN-payload diffs |

**H1: Rejected.** sin/cos/tan/exp/log all show real, measured divergence — always
≤2 ULP, but real. Fingerprints show the actual clustering:

```
exp   node=62b1a93d  jsc=b2d2181a  spidermonkey=62b1a93d  bun=b2d2181a
```

V8 and SpiderMonkey agree with *each other* on `exp`; JSC and bun (which embeds JSC,
not V8) agree with *each other* and diverge from V8/SpiderMonkey. `sin`/`cos`/`tan`
cluster the other way — V8 alone differs from JSC+SpiderMonkey+bun. There's no single
"odd one out" engine; which engine is the outlier depends on the function.

**`pow` came back fully bit-identical everywhere** — 164/300 finite results and
136/300 domain-error NaNs, all matching across V8/JSC/SpiderMonkey exactly, including
the NaN payload. This is the honest result within our test domain (base magnitudes
`1e-8`..`1e8`, exponent range ±10) — reported as measured, not forced to match the
"H1 rejected" pattern. It does not mean `Math.pow` is guaranteed bit-identical in
general, only that this run didn't find a counterexample.

**A concrete V8-vs-JSC NaN payload difference** (from `log`, idx 1): both engines
correctly return NaN for `Math.log(negative)`, but with different bit patterns:

```
node (V8):            0x7ffc000000000000
jsc (JavaScriptCore):  0x7ff8000000000000   (the more common "canonical" quiet NaN)
```

Neither is wrong — IEEE-754 doesn't mandate a specific NaN payload — but it's a
second, independent axis of cross-engine divergence beyond ULP differences on finite
results.

### WASM row — same `.wasm` module, every host (H2 / H3 control), reference = node

| function | jsc | js (SpiderMonkey) | bun | wasmtime (no JS) |
|---|---|---|---|---|
| add / sub / mul / div / sqrt | identical | identical | identical | identical |
| sin / cos / tan / pow / exp / log | identical | identical | identical | identical |

**H2: Confirmed.** Zero divergence, on any function, across any of the 5 hosts —
including `wasmtime`, which never touches a JS engine at all. Fingerprints match
exactly across the board, e.g.:

```
log   node=9b5dd78e  jsc=9b5dd78e  spidermonkey=9b5dd78e  bun=9b5dd78e  wasmtime=9b5dd78e
```

Notably this includes NaN payload bits too — unlike the JS row, WASM's `log` NaN
results match bit-for-bit everywhere, because every host is executing the literal
same `libm` bytecode rather than 4 independent native implementations.

**H3: Confirmed** for both rows — arithmetic and `sqrt` are bit-identical in every
cell of both tables, exactly as IEEE-754 requires.

### H4 — the mechanism

```
$ wasm-objdump -x output/determinism_full.wasm | grep -A3 'Import\['
(no output — zero imports)

$ wc -c output/determinism_arith_only.wasm output/determinism_full.wasm
     180 output/determinism_arith_only.wasm
   10372 output/determinism_full.wasm
```

- **Zero imports.** `output/determinism_full.wasm` has no host import section at
  all — confirmed with `wasm-objdump -x`. Nothing calls out to a host `sin`/`cos`;
  the entire implementation is self-contained inside the module.
- **Size delta: 10,192 bytes.** Same source, same compiler flags (`opt-level = "z"`,
  LTO, `codegen-units = 1`, stripped), same crate — the only difference is whether
  `sin`/`cos`/`tan`/`pow`/`exp`/`log` are compiled in. That 10.2KB *is* the bundled
  `libm` implementation, made visible. Determinism here is bought with bytes, not
  free.
- **Caveat, not a free lunch:** the module is pinned to whatever `libm` version the
  toolchain linked (`libm = "0.2.16"` at build time, see `rust/compute/Cargo.toml`).
  A `libm` version bump could in principle change results in the low bits — the
  determinism guarantee is "this module always computes the same thing," not "this
  algorithm is eternally fixed." Reproducibility requires pinning the dependency,
  same as reproducibility of any other software artifact.

## Known WASM non-determinism (documented, not glossed over)

WASM is not universally deterministic — two categories are explicitly carved out by
the [core spec's non-determinism appendix](https://github.com/WebAssembly/design/blob/main/Nondeterminism.md),
neither of which our test happened to trigger (our `libm`-produced NaNs came back
bit-identical everywhere — see H2 above):

- **NaN bit patterns.** Quoting the spec directly: *"When an arithmetic operator
  returns NaN, there is nondeterminism in determining the specific bits of the
  NaN"* — constrained only in that the result's fraction-field 1-bits must be a
  subset of the inputs' (except the top fraction bit). Separately: *"When an
  arithmetic operator with a floating point result type receives no NaN input
  values and produces a NaN result value, the sign bit of the NaN result value is
  nondeterministic."* This is a real, spec-sanctioned category — distinct from what
  we measured, since our results happened to agree, but a WASM engine is not
  required to reproduce another engine's NaN payload in general.
- **Relaxed-SIMD is non-deterministic by design.** Per the
  [relaxed-simd proposal](https://github.com/WebAssembly/relaxed-simd/blob/main/proposals/relaxed-simd/Overview.md):
  *"Some operators are host-dependent, because the set of possible results may
  depend on properties of the host environment (such as hardware)."* Concretely,
  relaxed fused-multiply-add may round once or twice depending on hardware FMA
  support, relaxed min/max is implementation-defined for NaN/±0 inputs, and relaxed
  swizzle is implementation-defined for out-of-range indices. This is an explicit,
  intentional trade of determinism for performance — opt-in, and orthogonal to the
  scalar `libm`-based determinism this experiment measured.

## When this matters

- **Lockstep multiplayer / rollback netcode.** Clients simulate independently and
  must reach identical state from identical inputs; a single-ULP trig divergence
  desyncs the simulation.
- **Replay systems.** A recorded input log should reproduce byte-identical output
  on replay, including on a different machine/OS than the one that recorded it.
- **Distributed agreement on computed values** (see below) — any protocol where
  multiple parties independently compute a value and must agree on it bit-for-bit.
- **Scientific reproducibility.** A published result should be re-derivable from the
  same code and inputs regardless of who runs it or where.

**Open question, not verified here:** several WASM-oriented blockchain/smart-contract
platforms are reported to restrict or forbid floating-point (or canonicalize NaNs,
or disable float/SIMD opcodes entirely) in deterministic execution contexts, precisely
because of the categories documented above. General secondary sources describe this
pattern (e.g. discussion of NaN canonicalization on the Internet Computer, and
smart-contract runtimes disabling float/SIMD opcodes for consensus-critical code), but
we did not verify a specific platform's source code or spec against a primary source
as part of this experiment — treat this paragraph as a lead for further reading, not
a confirmed fact of this experiment.

## Running

```bash
make build   # build both wasm-lib variants + wasmtime driver
make test    # validate wasm outputs, confirm zero imports
make matrix  # run the full {JS impl, WASM impl} x {host} matrix, print the report
make size    # just the H4 size table
make clean
```

`run_matrix.sh` skips any host that isn't installed and says so explicitly — it never
silently drops a host from the report. Raw per-host CSV captures land in `results/`
(gitignored, regenerate anytime with `make matrix`).

## Prerequisites

```bash
rustup target add wasm32-unknown-unknown wasm32-wasip1
brew install wasmtime wabt spidermonkey bun   # wabt → wasm-objdump; jsc ships with macOS
cargo install wasm-tools                       # wasm-tools validate
```
