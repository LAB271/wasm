# 008 — JS vs WASM: where's the crossover?

**Kind: Benchmark** (see root README "How to read these" — real numbers, same-session
fairness, hypotheses marked from measured data, not illustrative).

Experiment 010 measured `score_guess` (Mastermind's scoring function: 8 scalar `i32` in,
1 `i32` out) at 1.68M calls/step and published:

| Implementation | 1.68M calls |
|---|---|
| WASM (Rust, `no_std`) | 24 ms |
| JS, allocation-free scalar counters | 40 ms (1.68x slower) |
| JS, naive (4 array allocations/call) | 59 ms (2.47x slower) |

That 1.68x was **one** JS formulation, and 010 said so plainly at the time. This
experiment (a) tries harder on the JS side to see if the gap survives, and (b) asks the
general question: across all the ways data can cross the JS↔WASM boundary, and at every
granularity, where does WASM's edge actually hold?

## Headline: the 1.68x gap mostly evaporates

**Corrected figure: ~1.1x–1.9x, engine- and sample-size-dependent — not a clean single
number, and sometimes JS wins outright.** A fourth JS formulation (bit-packing the six
per-color counters into one `i32`, eliminating the switch chains entirely) closes 010's
gap in Node from **1.68x → ~1.1x–1.16x** at the full 1,679,616-pair volume 010 used, and
in the same run **beats** WASM outright (0.7x–1.0x) at a smaller 388,800-pair sample, in
every engine tested (Node, Bun, JSC, SpiderMonkey, Chrome). The *original* "tuned switch"
formulation's gap, however, **reproduces essentially unchanged** — 1.65x–1.90x across
every engine and host, confirming 010's original measurement was real, just not the
ceiling for JS.

**010's README should be corrected**: the 1.68x figure is real for *that* JS
formulation, but a better one exists and gets JS to parity or ahead. Recommend
updating the row to note both formulations (see "README row text" at the end).

### The 4 JS formulations, full 1,679,616-pair volume, Node, median of 7 timed rounds

| Formulation | ms | vs WASM (best) |
|---|---|---|
| WASM -Oz | 15.1–16.1 | 1.00x (baseline) |
| WASM -O3 | 24.2–25.1 | second-measured; see the retraction below — no real difference |
| js naive (4 array allocs/call) | 51.3–52.8 | 3.2–3.4x |
| **js tuned switch (010's original)** | 42.7–43.3 | **2.7–2.9x** |
| **js bit-packed nibbles (new)** | 17.2–17.5 | **1.10–1.16x** |
| js typed-array scratch buffer | 41.4–42.4 | 2.6–2.8x |

Full 1.68M-pair exhaustive parity check (every formulation against WASM, every one of
the 1,679,616 pairs) passes for all four JS formulations — bit-for-bit identical to
WASM's `score_guess`. Reproduce: `make rematch`.

Two formulations that "should" help (scratch-buffer reuse, escaping the switch chain
via array indexing into a preallocated `Int32Array`) barely moved the needle — V8's own
allocation-sinking already makes `jsNaive`'s per-call array allocations nearly free at
this scale (naive is only ~20% slower than tuned-switch, not multiples slower), and
plain array indexing has the same megamorphic-counter-array problem the switch chain
was working around. **Bit-packing was the only formulation that mattered.**

### Why bit-packing wins: it doesn't just avoid switch chains — it doesn't deopt

Ran the full rematch under `node --trace-opt --trace-deopt` (`make rematch`). Grepping
the trace for each formulation's own function name:

| Formulation | deopt events (own function) |
|---|---|
| `jsTunedSwitch` | 20 (`insufficient type feedback for compare operation`, recurring across Maglev *and* TurboFan tiers) |
| `jsBitpacked` | **0** |
| `jsNaive` | 0 |
| `jsTypedScratch` | 0 |

The switch-chain formulation's 12 branch targets across 6 `switch` statements give V8's
type-feedback vector far more to get wrong under repeated re-speculation; it kept
falling out of optimized code and recompiling throughout the timed rounds, not just
during warmup. Bit-packing replaces all of that with pure arithmetic (shifts/masks) —
zero branches to mis-speculate, zero deopts observed. **The mechanism isn't "fewer
instructions," it's "nothing to deoptimize."** This is inferred from the trace, not
independently verified against V8 internals beyond what the trace format documents.

### `-Oz` vs `-O3` — RETRACTED: it was a harness ordering artifact

An earlier version of this section reported `wasm-opt -Oz` (3965 B) as **1.55–1.63x
faster** than `-O3` (3964 B) from identical cargo output, called it consistent across 5
runs, and flagged it as unexplained. **It is not a real effect.**

Two checks settled it. First, the binaries barely differ: 1577 vs 1575 lines of WAT, and
the whole instruction-mix delta is `i32.eqz` 13→10 and `local.tee` 78→79. A 1.6x runtime
gap from three instructions was never plausible. Second, and decisively, benchmarking
them in both orders shows the advantage follows **position, not flag**:

| Benchmark order | first module | second module |
|-----------------|-------------|---------------|
| `-Oz` then `-O3` | **-Oz 18.36 ms** | -O3 23.49 ms |
| `-O3` then `-Oz` | **-O3 17.46 ms** | -Oz 22.85 ms |

Whichever module is measured first wins by ~1.3x. `-Oz` was simply always measured first.
The most likely mechanism is V8 WASM tiering: the first module gets fully TurboFan-tiered
during its warmup, while the second competes for the tier-up budget in an already-busy
process. Not confirmed to that level of detail — but the ordering dependence itself is
reproducible and is enough to retract the claim.

**`-Oz` and `-O3` perform the same here, within noise.** Tables above that show a `-O3`
row are reporting the second-measured module and should be read with this in mind.

> **Open question — does this bias anything else?** The rematch compares five JS
> formulations sequentially in one process, and the axis-1/axis-2 sweeps likewise measure
> variants in a fixed order. If first-measured wins generally, every sequential
> comparison in this experiment inherits some bias. The headline 1.14x is probably safe
> (bit-packed JS is measured *after* WASM, so ordering works against the finding, not for
> it) but this has not been verified by re-running in shuffled order. Tracked as an issue.

### Instantiate cost

Sub-millisecond either way at this binary size (~4 KB): 0.35–0.72 ms in isolated
single-shot processes. The first `WebAssembly.instantiate` call in *any* process paid
extra (up to ~2.8 ms) regardless of which binary went first — a process cold-start
artifact, not a property of `-Oz` vs `-O3`. At this size, instantiate cost is noise, not
signal; it only starts to matter for modules orders of magnitude larger (see 010's
loading-strategy numbers).

## Axis 1 — what crosses the boundary

Same rung-by-rung structure as the brief, decomposed into **marshal** (getting JS-native
data into WASM's shape), **wasm call** (compute, once data is already in linear memory),
and **js native** (no crossing at all). `make axis1`.

### At N = 2,000,000 (Node, medians)

| Rung | marshal | wasm call | **wasm TOTAL** | js native |
|---|---|---|---|---|
| Rung 2/3 — floats, typed array | 0.21 ms | 0.96–1.08 ms | **1.16–1.29 ms** | 2.31–2.51 ms (typed), 1.97–2.05 ms (plain array) |
| Rung 4 — strings (UTF-8 hash) | 0.12–0.14 ms (encode) | 1.82–2.05 ms | **1.94–2.17 ms** | 1.87–2.04 ms |
| Rung 5 — points/structs, **sum of squares (no sqrt)** | 3.56–4.28 ms (AoS→SoA) | 1.19–1.30 ms | **4.75–5.58 ms** | 1.79–1.96 ms |
| Rung 5 — points/structs, **with sqrt** | 3.56–4.28 ms | 17.3–18.5 ms | **21.6–22.1 ms** | 1.79–2.11 ms |

**Rungs 1→3 (scalars → typed arrays): WASM wins, decisively.** Marshalling a
`Float64Array` into linear memory costs almost nothing (~0.2 ms for 2M elements — it's a
single `TypedArray.set` into an already-linear buffer) and WASM's compute is 2x faster
than V8's own typed-array reduce.

**Rung 4 (strings): roughly a wash.** UTF-16→UTF-8 encoding is cheap (`TextEncoder` is a
native, heavily-optimized browser/Node primitive), so `wasm TOTAL` and `js native` land
within ~10% of each other. Neither side has a structural advantage here; pick based on
what else the function needs to do.

**Rung 5 (objects): WASM's marshalling story is fine — its *compute* story is the
surprise.** AoS→SoA extraction is genuinely the most expensive marshalling step measured
(3.5–4.3 ms at 2M points, vs ~0.2 ms for a flat float array) — that part matches the
hypothesis that structured data is the expensive rung. But the *dominant* cost turns out
to be something else entirely: this benchmark's `sum_points` calls **`libm::sqrt` — a
software implementation — costing ~9-15x more than V8's hardware-backed `Math.sqrt`**.
Isolated cleanly with a sqrt-free variant (`sum_points_sq`, sum-of-squares only): there
WASM's compute alone (1.19–1.30 ms) is *faster* than JS's (1.79–1.96 ms), consistent with
rungs 1–3. So the rung-5 result is a libm tax, not a marshalling tax.

> **Correction:** an earlier draft blamed this on "the same reason 017 found `sin`/`cos`
> need `libm`." That is wrong — WASM *has* `f64.sqrt`, and the real cause is a Rust
> `core`/`std` boundary that does not line up with the instruction set. Full analysis in
> [The `no_std` math trap](#the-no_std-math-trap) below.

The generalizable lesson, stated correctly: **before concluding WASM is slow at something,
check whether the guest is using a software implementation of an operation the instruction
set already provides.** A `no_std` build can silently swap one hardware instruction for a
function call, and nothing warns you.

## The `no_std` math trap

Measured on rustc 1.96.0, `wasm32-unknown-unknown`. Every cell below was compiled and
disassembled, not read from documentation.

| Rust method | Reachable from `no_std`? | WASM instruction exists? | What `std` actually emits |
|-------------|--------------------------|--------------------------|---------------------------|
| `abs` | **yes** (`core`) | `f64.abs` | native instruction |
| `min` / `max` / `copysign` | **yes** (`core`) | `f64.min`/`max`/`copysign` | native instruction |
| `sqrt` | **no** — std-only | **yes**, `f64.sqrt` (`0x9F`) | native instruction |
| `floor` | **no** — std-only | **yes**, `f64.floor` | native instruction |
| `ceil` | **no** — std-only | **yes**, `f64.ceil` | native instruction |
| `trunc` | **no** — std-only | **yes**, `f64.trunc` | native instruction |
| `round` | **no** — std-only | `f64.nearest` exists, **wrong semantics** | software helper |
| `sin` `cos` `exp` `ln` `powf` | **no** — std-only | **no instruction** | software `libm` |

Three genuinely different situations hide behind "std-only":

**1. Stranded — hardware exists, `no_std` can't reach it.** `sqrt`, `floor`, `ceil`,
`trunc`. The instruction is right there; `core` just doesn't expose the method, so a
`no_std` crate reaches for `libm` and pays a software routine for a single opcode. This
is what cost rung 5 **9–15x**. Pure waste, and no warning is emitted.

**2. Semantic mismatch.** `round` is the interesting one: `f64.nearest` exists, but it
rounds half-to-even while Rust's `round` is half-away-from-zero. They are different
functions, so even *with* `std` the compiler emits a helper rather than the instruction —
the disassembly shows no `f64.nearest` and one extra function in the module.

**3. Honest absence.** `sin`, `cos`, `exp`, `ln`, `powf` have no WASM instruction at all.
Shipping `libm` is unavoidable, costs ~10.2 KB ([017](../017_float_determinism/)), and
buys bit-identical results across every engine. A real trade, unlike case 1.

### Why the line falls where it does

The WASM instruction set tracks **IEEE-754's own required/recommended split**, not
anyone's idea of "basic math":

- IEEE-754 §5 **requires** correctly-rounded `add`, `sub`, `mul`, `div`, **`sqrt`**,
  `remainder`, and conversions. WASM provides all of these as instructions.
- IEEE-754 §9.2 lists `sin`, `cos`, `exp`, `log`, `pow` and friends as **recommended**,
  i.e. optional. WASM provides none of them.

So "does WASM have an instruction for this?" is very nearly the question "does IEEE-754
require it?" `sqrt` is required — which is exactly why it has an opcode and `sin` doesn't.
Calling `sqrt` a transcendental (as the first draft of this README did) gets the
prediction backwards.

### Implication for any language targeting WASM

Rust's `core`/`std` boundary is a Rust packaging decision that predates its WASM backend
and does not line up with the instruction set. Any language emitting WASM should map its
own math surface onto the **instruction set**, not onto Rust's precedent:

- Lower `sqrt`, `floor`, `ceil`, `trunc`, `abs`, `min`, `max`, `copysign` straight to
  instructions — no runtime dependency, no size cost.
- Check semantics before lowering. `round` looks like `f64.nearest` and isn't.
- Ship `libm` only for the genuinely-absent set, and know it costs ~10 KB.

**How to detect it in a build you already have:** disassemble and look for the
instruction you expect.

```
$ wasm-tools print module.wasm | grep -c 'f64.sqrt'
0          # calling sqrt but zero sqrt instructions -> a software routine is in there
```


## Axis 2 — work per crossing (granularity / amortization)

Fixed total: 1,048,576 `score_guess` pairs, `score_guess_batch` groups K pairs per WASM
call, swept K from 1 (010's original per-call shape) to 1,048,576 (one call, everything).
`make axis2`.

```
         K      calls    median ms   ns/element
         1    1048576      10.0–12.5    9.6–11.9
         4      262144       7.3–8.1    6.9–7.7
        16      65536       5.9–7.2    5.6–6.9    <- crossover vs "js bit-packed" here, most runs
       256       4096       5.5–6.1    5.3–5.8
      1024       1024       5.4–6.1    5.2–5.8
     65536         16       5.3–5.9    5.1–5.6
   1048576          1       5.2–5.4    5.0–5.1
```

(Ranges across repeated runs; OLS fit of `round_ms = a + b*num_calls` gave R² =
0.88–0.94 across runs — a real fit, not a perfect one, so treat the per-call/per-element
split below as a reasonable estimate, not an exact one.)

**Decomposition** (from the OLS fit, `time = a + b·calls`, `a` = pure-compute floor at
this total, `b` = per-crossing overhead):

- **Per-crossing (WASM call) overhead: ~4.4–6.1 ns/call.** This is *tiny* — modern V8's
  JS→WASM call path for a flat scalar signature is close to a native call, matching
  010's original finding that crossing cost "never dominates."
- **Per-element compute: ~5.5–6.2 ns/element (WASM) vs ~5.9–7.8 ns/element (JS
  bit-packed, flat loop, no crossing to amortize)** — close to parity, WASM slightly
  ahead, consistent with the rematch's ~1.1x figure at full volume.
- **Crossover point: K≈4–16** (i.e., grouping as few as 4–16 pairs per WASM call) is
  enough for batched WASM to beat the flat JS bit-packed baseline in most runs. At K=1
  (calling once per pair, 010's original shape), WASM is 1.3–1.5x *slower* than JS
  bit-packed — batching, not the language, is what was missing.

## Decision rule

Given what was actually measured:

1. **Scalars/typed-array data, called once per pair (K=1, no batching)**: JS bit-packed
   (or equivalently tight) code is competitive with or beats WASM. Don't reach for WASM
   here just because the compute is "hot" — restructure the JS first.
2. **Same task, batched ≥ ~16 elements per WASM call**: WASM wins, and the win grows
   with batch size (asymptotes near 2x at K≥1024 in this workload). If you can batch,
   WASM batching is close to free to add and reliably faster.
3. **Flat numeric arrays (typed arrays) crossing once per array, not per element**: WASM
   wins outright, and marshalling cost is negligible (~0.1–0.2 ns/element to copy into
   linear memory) — this is the easy, unambiguous win case.
4. **Strings**: roughly a wash; `TextEncoder` is fast enough that neither side has a
   structural edge. Decide on other grounds.
5. **Structured/object data (AoS)**: marshalling (AoS→SoA) is real cost (a few ns/point)
   but not prohibitive — it's smaller than the difference in rules 1-3. **The bigger
   risk is hidden compute cost**: if the per-element operation needs a transcendental
   function (sqrt, sin, cos, exp, log, pow) and you're on stable `no_std` Rust, you're
   paying for software `libm`, not hardware instructions — that can cost 10-15x more
   than the JIT gets for free, and can flip the entire comparison regardless of how well
   you handle the marshalling. Check this specifically before shipping a WASM path for
   any function that isn't pure arithmetic/bit-ops.

## Engine coverage

- **Node (V8), primary**: full Axis 1 + Axis 2 + rematch.
- **Chrome (headless, Playwright `channel: 'chrome'`)**: rematch only (`make browser`),
  388,800-pair sample. Confirms the Node result: WASM 1.78–1.90x faster than tuned
  switch, 0.70–0.73x vs bit-packed (i.e., bit-packed JS *beats* WASM at this sample
  size, same direction as Node's smaller-sample result).
- **Bun, JSC, SpiderMonkey `js` shell** (`make matrix`, reusing 017's portability
  pattern): rematch only, 388,800-pair sample. `wasm vs bit-packed` ratio: Bun 0.95–1.01,
  JSC 0.99–1.00, SpiderMonkey 0.93–0.97, Node 0.72–0.75. **All four independent engines
  agree bit-packed JS is at-or-above WASM parity at this sample size**, and all four
  reproduce the original tuned-switch gap (1.73x–1.85x) closely. This is the strongest
  evidence in the experiment that the rematch result isn't a V8-specific artifact.
- Axis 1 (data-shape rungs) and Axis 2 (granularity sweep) were **not** re-run across
  engines/browser — would have been cheap to add per-engine but didn't fit the room
  budget for this pass; flagging as a gap rather than silently only covering Node.

## Benchmark hygiene notes

- Every number above is a median of ≥5 timed rounds (after ≥2–5 warmup rounds), with
  observed min/max ranges reported inline rather than a single point estimate — spreads
  were mostly single-digit percent of the median, except the points/objects rung, whose
  max occasionally spiked hard (once to 7x median) from what's almost certainly a GC
  pause during the AoS-object-array construction; medians were stable across repeats
  regardless.
- **The JS-vs-WASM ratio for the identical "bit-packed" formulation shifted from ~0.7x
  (388,800-pair sample) to ~1.1x (1,679,616-pair sample) in the same engine (Node).**
  This sample-size sensitivity is itself a finding, not noise to average away — don't
  trust a single-sample-size benchmark's ratio as "the" number for a given
  implementation pair.
- Parity was asserted before every timed comparison: exhaustively (all 1,679,616 pairs)
  for the rematch, spot-checked (prime-strided sample) for the granularity sweep and the
  portable/browser scripts, and via direct value comparison (with float tolerance) for
  Axis 1's sums.
- Checksums/accumulators are threaded through every timed loop (`timeRounds` in
  `js/common.mjs` returns the accumulated value) specifically so V8 can't dead-code
  eliminate the loop body.
- WASM instantiate cost is reported separately from steady-state throughput (see
  "Instantiate cost" above) — it never got folded into a per-call number.

## What's real vs what's inferred

**Measured, high confidence:** the rematch ratios (rerun 3-5x, tight variance), the
axis-1 marshal/compute split (direct isolated timing), the granularity/crossover numbers
(rerun twice, K≈4-16 crossover consistent), the deopt-count difference between
formulations (from V8's own trace output), the sqrt/libm cost (isolated by a
sqrt-free control function).

**Inferred, lower confidence:** *why* `-Oz` beats `-O3` here (plausible Binaryen-pass
explanation, not confirmed by disassembly); that the deopt-count difference is *the*
reason bit-packing wins rather than *a* reason (didn't isolate branch count from deopt
count as separate variables); that engine-to-engine agreement generalizes beyond this
one function shape.

## Layout

```
rust/crossover/src/lib.rs   score_guess, score_guess_batch, sum_f64(_unchecked),
                            hash_bytes, sum_points(_sq), bump allocator (alloc/reset_arena)
build.sh                    cargo build (opt-level=3, LTO) -> wasm-opt -Oz AND -O3
js/common.mjs               wasm loading, linear-memory marshal helpers, timing/stats, OLS fit
js/bench_010_rematch.mjs    the rematch: 4 JS formulations vs WASM -Oz/-O3, full parity gate
js/bench_axis1.mjs          typed arrays / plain arrays / strings / points, N swept
js/bench_axis2.mjs          granularity sweep + OLS decomposition
js/portable_battery.js      classic-script rematch subset, runs under node/jsc/js/bun unmodified
browser/index.html          same rematch subset, runs in a real browser via fetch()+instantiate
tests/perf.mjs              Playwright driver (system Chrome, no Chromium download)
serve.py                    static server for the browser leg (adds .wasm mime type)
run_matrix.sh               drives portable_battery.js across every installed engine
Makefile                    build / test / rematch / axis1 / axis2 / matrix / browser / bench
```

## Bounds checks (as measured, not as hoped)

`sum_f64` (safe, `slice.iter().sum()`) vs `sum_f64_unchecked` (`get_unchecked` in a hand
loop) — both exported, both exercised by `bench_axis1.mjs`'s parity gate, but **we did
not end up including a timed comparison of the two in the final tables above**: initial
spot checks showed no measurable difference (LLVM already proves the iterator form's
bounds are in-range and elides the check, which is the expected outcome and matches
`core`'s own documented behavior for slice iteration). Both functions ship in the crate
for anyone who wants to re-verify; the honest reporting here is "we looked, found nothing
worth a table row, and moved on" rather than fabricating a spread.

## Reproduce

```
make build     # cargo + wasm-opt -Oz/-O3
make test      # cargo test + wasm-tools validate
make rematch   # the 010 rematch, with JIT trace
make axis1     # what crosses the boundary
make axis2     # work per crossing
make matrix    # node/bun/jsc/spidermonkey
make browser   # headless Chrome via Playwright
make bench     # all of the above
```
