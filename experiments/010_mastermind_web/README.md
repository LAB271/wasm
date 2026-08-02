# Experiment 010 — Mastermind, scored by WASM, in the browser

A real, deterministic, pure scoring function running in-browser, called directly
from a click-driven UI — zero server round-trips after the initial page load.
The scoring logic is written twice, in two languages that both compile straight
to WASM (no MVL, no extra IR): **Rust** (`wasm32-unknown-unknown`) and
**AssemblyScript**. The UI can load either one; both implement the exact same
function.

## Architecture

`score_guess(s0, s1, s2, s3, g0, g1, g2, g3) -> i32` is the entire ABI. Four
secret peg colors, four guess peg colors (0-5 each), one packed result:
`blacks * 16 + whites`. No structs, no strings, no linear-memory pointers, no
host imports — both compiled modules export nothing but `score_guess` and
`memory`, so loading either is just:

```js
const { instance } = await WebAssembly.instantiate(bytes, {});
instance.exports.score_guess(s0, s1, s2, s3, g0, g1, g2, g3);
```

No runtime shim, no glue code. Peg colors are display-only in the UI (color
names, CSS classes) — the only thing that crosses the WASM boundary is small
integers.

- `engines/rust/` — `score_guess`, compiled via `cargo build --target
  wasm32-unknown-unknown --release`. Also has `cargo test` unit tests for the
  scoring logic itself (native, no WASM involved).
- `engines/assemblyscript/` — the same function, compiled via `asc`. Uses
  scalar counters rather than arrays so the bounds-check `abort` import never
  gets pulled in (`--runtime stub --noAssert`, still zero imports).
- `web/` — the UI (`index.html`, `style.css`, `app.ts`). Click-to-pick colored
  pegs, dark theme, animated row entry, a live attempt counter, and a
  win/lose overlay. `crypto.getRandomValues` picks the secret client-side.

Switch engines at runtime with a query param: `?engine=rust` (default) or
`?engine=as`.

## Usage

```bash
make run                  # builds both engines + the UI, serves at :8010 (?engine=rust)
make run ENGINE=as        # same, but prints the URL for the AssemblyScript engine
make run PORT=9000        # different port
```

`make run` execs `serve.py` directly (no backgrounded process, no signal
handling needed) — Ctrl+C stops it.

Individual build targets: `make build-rust`, `make build-as`, `make build-ui`,
`make build-inline` (base64-encodes both `.wasm` files into importable ES
modules), or `make build` for all four. `make clean` removes build output.
`make help` (also the default target) lists everything with a one-line
description.

Two extra loading modes, both covered in [Fetch vs. Inline-Base64
Loading](#fetch-vs-inline-base64-loading) below:

```bash
# Real game, but loads the engine from the inlined base64 module instead of fetch()
open "http://127.0.0.1:8010/?engine=rust&inline=1"

# Side-by-side fetch vs inline comparison page, with measured numbers
open "http://127.0.0.1:8010/inline.html?engine=rust"

# CORS demo: a second server acting as a foreign origin, with/without CORS headers
python3 serve.py 8011 --no-cors
# then on the inline.html page, set "Foreign-origin port" to 8011 and click
# "Test cross-origin fetch" — the fetch() is blocked, the inline load isn't.
```

## Testing

```bash
make test           # everything below
make test-unit       # cargo test (Rust logic) + tests/wasm.test.mjs (both compiled .wasm files, in Node)
make test-browser    # tests/browser.test.mjs — real headless Chrome, both engines, full click-through
```

`test-unit` loads both compiled `.wasm` artifacts directly in Node (no browser,
no server) and checks known scoring cases plus a 200-case randomized parity
sweep between the two engines, plus a regression check that each
`engine-*.b64.js` decodes byte-identical to its `.wasm` and scores correctly
(catches a stale or corrupted `build-inline` step). `test-browser` launches
the system-installed Chrome via Playwright (`channel: 'chrome'` — no separate
browser download), loads the real served page for each engine, plays a full
guess through the UI, and asserts feedback pegs render correctly with zero
console errors.

## Structure

```
010_mastermind_web/
├── README.md
├── Makefile                       # build-rust, build-as, build-ui, build-inline, build, run, test, clean
├── serve.py                        # static server, pre-compressed .wasm/.js serving, CORS (+ --no-cors)
├── engines/
│   ├── rust/                       # score_guess, cargo test covers the scoring logic
│   └── assemblyscript/             # score_guess, same ABI, no host imports
├── tests/
│   ├── wasm.test.mjs               # both engines + both .b64.js modules, direct WebAssembly.instantiate, in Node
│   └── browser.test.mjs            # real headless Chrome, full UI click-through
└── web/
    ├── index.html
    ├── inline.html                  # fetch vs inline-base64 loading comparison + CORS demo
    ├── style.css
    ├── app.ts                      # game logic + WASM interop (?inline=1 loads the base64 module)
    ├── inline.ts                   # standalone comparison/measurement page logic
    └── package.json                # typescript, dev-only
    # engine-rust.wasm, engine-as.wasm, engine-*.b64.js, dist/ are build output, gitignored
```

## WASM Size Optimization — A Case Study

For trivial functions, WASM binary size varies dramatically by language and build
configuration. This experiment documents the journey from 16KB to 950 bytes for
the same Rust function:

| Configuration | Size | Brotli | Notes |
|---------------|------|-------|
| Rust default (`std`) | 16 KB | — | Includes panic handling, allocator stubs, LLVM glue |
| Rust `#![no_std]` | 3.1 KB | — | Removes stdlib, requires custom panic handler |
| Rust `#![no_std]` + `wasm-opt -Oz` | **950 B** | **634 B** | Binaryen optimizer strips dead code |
| AssemblyScript | **481 B** | **268 B** | Designed for WASM, near 1:1 compilation |

*Brotli column shows HTTP transfer size (`make size` for current values).*

### Why the difference?

**Rust** compiles via LLVM, a general-purpose backend. Even with aggressive
optimization flags (`opt-level = "z"`, LTO, `panic = "abort"`, `strip = true`),
a minimal `std` binary includes:
- Panic handling infrastructure (unwinding or abort stubs)
- Memory allocator shims (even if unused)
- LLVM-generated defensive code paths

**AssemblyScript** is purpose-built for WASM. The language maps directly to WASM
primitives — no runtime overhead, no hidden allocators. For pure compute
functions like `score_guess`, this is nearly 1:1 with hand-written WAT.

### How to minimize Rust WASM size

The optimization happens in two stages — **Rust/LLVM** and **Binaryen/WASM**:

| Step | Reduction | Toolchain | What it does |
|------|-----------|-----------|--------------|
| `#![no_std]` | 16KB → 3.1KB | Rust | Removes stdlib, panic infra, allocator |
| `wasm-opt -Oz` | 3.1KB → 950B | Binaryen | WASM-specific dead code elimination |

**Stage 1: Rust/LLVM** (compile-time)

1. **Use `#![no_std]`** — eliminates stdlib overhead (requires panic handler):
   ```rust
   #![no_std]
   
   #[cfg(target_arch = "wasm32")]
   #[panic_handler]
   fn panic(_: &core::panic::PanicInfo) -> ! {
       loop {}
   }
   ```

2. **Cargo.toml release profile**:
   ```toml
   [profile.release]
   opt-level = "z"      # optimize for size (LLVM)
   lto = true           # link-time optimization (LLVM)
   panic = "abort"      # no unwinding
   strip = true         # strip symbols
   ```

**Stage 2: Binaryen/WASM** (post-process)

3. **Post-process with `wasm-opt`** (from Binaryen):
   ```bash
   wasm-opt -Oz input.wasm -o output.wasm
   ```
   
   Binaryen understands WASM natively and applies transformations LLVM can't:
   - Dead code elimination (removes unreachable functions)
   - Instruction combining (merges redundant ops)
   - Stack/local optimization (WASM-specific register allocation)
   - Code deduplication

**Why both stages matter:** Rust compiles via LLVM, a general-purpose backend that
targets WASM but doesn't understand it deeply. Binaryen is WASM-native — it sees
patterns LLVM misses. AssemblyScript uses Binaryen directly (no LLVM), which is
why it starts small without needing a separate optimization pass.

### When does this matter?

- **Browser apps** — every KB counts for initial load time
- **Edge/serverless** — cold start includes WASM compilation
- **Embedded** — memory constraints are real

For **server-side WASM** with `std` (file I/O, networking, serde), the 16KB
overhead amortizes against 100KB+ of actual application code. Don't sacrifice
ergonomics for size when size doesn't matter.

## Fetch vs. Inline-Base64 Loading

A [Medium
post](https://aws.plainenglish.io/awss-stealth-container-killer-we-replaced-docker-with-a-browser-and-slashed-costs-by-60-43fceea80b15)-adjacent
pattern we wanted real numbers on: instead of `fetch()`ing a `.wasm` binary,
base64-encode it into a JS string and ship it as part of an already-loaded
module — `WASM_B64` in `web/engine-{rust,as}.b64.js`, generated by `make
build-inline`. The motivation is dodging three real failure modes: a
cross-origin `.wasm` fetch blocked by CORS, a host that serves `.wasm` with
the wrong (or no) `application/wasm` MIME type, and `fetch()` of `file://`
URLs being disallowed in some mobile webviews (a plain `<script>` tag mostly
isn't). `web/inline.html?engine=rust|as` loads the engine both ways and
measures each with the Resource Timing API + `performance.now()`; `web/app.ts`
itself can also run off the inlined module via `?inline=1`.

### Measured: size (this repo's artifacts)

| | Raw | Gzip | Brotli |
|---|-----|------|--------|
| Rust `.wasm` | 950 B | 660 B | 634 B |
| Rust `.b64.js` | 1296 B | 880 B | 840 B |
| **Rust expansion penalty** | **+36.4%** | **+33.3%** | **+32.5%** |
| AS `.wasm` | 481 B | 325 B | 268 B |
| AS `.b64.js` | 672 B | 441 B | 390 B |
| **AS expansion penalty** | **+39.7%** | **+35.7%** | **+45.5%** |

(`make size` prints this table for the current build, including the two
b64-inline rows.) Base64 expands raw bytes by exactly 4/3 (33.3%), and the
common assumption is that gzip/brotli "absorb" most of that back because
base64 only uses 6 bits/byte. **Measured, that assumption doesn't hold for
these artifacts** — the post-compression penalty is *roughly the same
magnitude* as the raw penalty (32–45%), not meaningfully smaller. At these
tiny sizes, compressor framing/dictionary overhead dominates, and the
AS module is *worse* compressed (45.5%) than raw (39.7%). Don't assume
compression bails you out of the base64 tax — measure your own artifact.

### Measured: JS compression (dist/app.js, dist/inline.js)

`serve.py`'s pre-compressed-sidecar serving isn't `.wasm`-specific — it's
extension-driven (`COMPRESSIBLE_EXTS = (".wasm", ".js")`, Content-Type from
`extensions_map`), so the same `make build`-time gzip/brotli step that covers
the wasm engines and the `.b64.js` modules also covers the compiled game and
comparison-page JS:

| | Raw | Gzip | Brotli |
|---|-----|------|--------|
| `dist/app.js` | 18735 B | 5349 B (−71.4%) | 5046 B (−73.1%) |
| `dist/inline.js` | 7479 B | 2610 B (−65.1%) | 2409 B (−67.8%) |

Ordinary JS text compresses far better than base64 WASM text does (65–73%
here vs. the 30–45% *penalty* the b64 modules carry) — base64's near-uniform
byte distribution gives a general-purpose compressor much less to work with
than a hand-written program's repetitive tokens/whitespace.

### Measured: requests, bytes, timing (localhost, Chrome, `inline.html`)

With `.b64.js` now served brotli-compressed like everything else, this is
finally an apples-to-apples comparison — both columns are the real
over-the-wire bytes for their loading path, not raw-vs-compressed:

| | fetch() | inline base64 |
|---|---------|----------------|
| Requests (Rust) | 1 | 1 |
| Bytes transferred (Rust, Resource Timing `transferSize`) | 934 B | 1140 B |
| Requests (AS) | 1 | 1 |
| Bytes transferred (AS) | 568 B | 690 B |
| Decode time | ~0.1–2 ms | ~0.1–1 ms |
| `WebAssembly.instantiate` | ~0.3–2.5 ms | ~0–2.1 ms |
| Total time-to-first-`score_guess` | ~3–9 ms | ~7–12 ms |

Bytes transferred were stable across repeated runs (identical on 3
consecutive measurements each); the decode/instantiate/total timings above
show the full spread observed across those runs, not a single sample.

**The conclusion does not flip: fetch still transfers fewer bytes for both
engines**, even after fixing the compression gap — 934 B vs. 1140 B for
Rust (+22%), 568 B vs. 690 B for AS (+21%), tracking the brotli expansion
penalty from the size table above (+32.5% / +45.5%) minus a shared ~300 B
fixed per-request overhead that Chrome's Resource Timing API adds to every
`transferSize` regardless of body size. Two honesty notes that still stand:

- **Request count is a tie here, not a win for inline** — in this unbundled
  demo, `engine-*.b64.js` is still its own network request, same as
  `engine-*.wasm`. The real win of inlining only appears when the base64
  string is bundled directly into a JS file the page was already going to
  load (no separate wasm-shaped request at all); we didn't build a bundler
  step, so that scenario isn't reflected in the request-count row above.
- **Timings are localhost-understated, not a real speedup.** RTT ≈ 0 here, so
  inlining's actual advantage — skipping one network round trip — is worth
  ~1 RTT on a real network and ~nothing on localhost. Treat the timing rows
  as noise; request count and bytes are the numbers that generalize.

### When inlining wins

- Payload is genuinely tiny (a few hundred bytes to a few KB, like this
  experiment's engines) — the byte penalty is small in absolute terms even
  though it's large in percentage terms.
- No control over the serving host's MIME types or CORS headers (third-party
  CDN, embedded widget, `file://` distribution).
- Mobile webviews or restrictive `file://` contexts where `fetch()` of local
  or cross-origin binaries is blocked but a `<script>`/module load isn't.
- You already ship one JS bundle and don't want a second binary asset in the
  deploy artifact.

### When it loses

- Larger modules: you forfeit `WebAssembly.instantiateStreaming`, which
  compiles the module *while it downloads*. A fetched binary streams and
  compiles in parallel; a base64 string must fully arrive, then get
  base64-decoded, before `WebAssembly.instantiate` can even start. For a
  multi-hundred-KB-plus module, that serialization plus the ~33% size tax
  outweighs saving one request.
- Any server you control where you can just set the right MIME type and CORS
  header — the two problems inlining sidesteps are the two things this
  experiment's `serve.py` now does properly (see the CORS section below).

### Compressing *before* base64, and why it usually doesn't help

Obvious next idea: compress the `.wasm` first, then base64 the compressed bytes,
and decompress at runtime. Measured on `engine-rust.wasm` (950 B):

| Pipeline | Wire bytes |
|----------|-----------|
| `brotli(wasm)` — plain fetch | **634** |
| `brotli(b64(brotli(wasm)))` | 665 |
| `brotli(b64(gzip(wasm)))` | 683 |
| `brotli(b64(wasm))` — inline as built here | 806 |

It genuinely saves ~141 B: the outer brotli still recovers base64's 6-bits-per-byte
packing even though the payload beneath is incompressible. But you now need a
decompressor at run time. `DecompressionStream` is native and free, though reliably
only for gzip/deflate (brotli support there is newer and patchier), so realistically
you land on the 683 row — and the `DecompressionStream` → `ArrayBuffer` →
`WebAssembly.instantiate` plumbing costs roughly 150 compressed bytes of glue. 683 +
150 ≈ 833, which is where you started.

The reason is structural: **you are reimplementing `Content-Encoding` in userspace**,
and the server already does it natively for zero bytes of JS.

The exception is the case that motivates inlining in the first place — `file://`, a
mobile webview, no control over headers. There *is* no server compression to lean on,
so the comparison becomes 1268 B (raw base64, nothing compressing it) versus 848 B
(base64 of brotli'd wasm, self-decompressed): a **33% saving**, and now the glue is
worth paying for. The technique is redundant exactly when you don't need inlining, and
worthwhile exactly when you do.

### Was WASM even worth it here?

Worth asking plainly, since this experiment exists to make the tradeoff legible rather
than to sell WASM. `score_guess` is ~20 lines of integer comparison. Hand-written
JavaScript would be roughly 200 B brotli'd, against 634 B for the fetched `.wasm` and
806 B inlined. **On size, JS wins outright — roughly 3x.**

On speed, the intuition that a trivial function called across the JS↔WASM boundary
would be dominated by crossing overhead turns out to be **wrong**. The solver's inner
loop (`allGuesses × poss`) issues up to ~1.68M `score_guess` calls per step. Measured
in Node on that exact call volume:

V8's JS→WASM call overhead for a flat all-integer signature is low enough that it never
dominates — [020](../020_js_vs_wasm_crossover/) later measured it at **~5.5 ns per
crossing**. WASM wins on the compute itself, not by avoiding the boundary.

**Corrected figure.** This section first published a 1.68x WASM advantage, measured
against a "tuned switch" JS formulation. That formulation was not the fastest available.
[020](../020_js_vs_wasm_crossover/) re-ran the same 1.68M-call workload across five JS
formulations, all parity-checked bit-for-bit against the WASM:

| Implementation | 1.68M calls (median of 7) | vs WASM |
|----------------|--------------------------|---------|
| WASM (Rust, `no_std`, `wasm-opt -Oz`) | **15.2 ms** | — |
| **JS, bit-packed nibbles** | **17.4 ms** | **1.14x slower** |
| JS, typed-array scratch | 41.7 ms | 2.74x |
| JS, tuned switch — *the original 1.68x came from here* | 42.3 ms | 2.78x |
| JS, naive (4 array allocations per call) | 51.5 ms | 3.39x |
| WASM, `wasm-opt -O3` | 24.2 ms | 1.59x *slower than `-Oz`* |

**The mechanism is deoptimization, not instruction count.** 020 re-ran the rematch under
`node --trace-opt --trace-deopt`: the tuned-switch version **deoptimizes 20 times**,
including mid-timed-round, because the switch chains never accumulate enough type
feedback for TurboFan to commit. The bit-packed version has **zero** branches to
mis-speculate and **zero** deopt events. It isn't executing fewer instructions so much as
never falling out of optimized code.

**How close is it really?** Close enough that the direction depends on the harness. The
direct rematch above puts WASM 1.14x ahead; 020's granularity sweep, calling one pair at
a time through its batch entry point, puts bit-packed JS **1.3–1.5x ahead**. Per-element
compute is ~5.5–6.2 ns for WASM against ~5.9–7.8 ns for JS. The honest reading is
**parity**, not a win for either — and every measurement agrees the 1.68x is gone.

So the verdict is narrower than first written: **~3x the bytes for roughly break-even
speed.** For manual play — ten calls per game — the WASM is pure overhead. For the
solver, it is not a reason to ship a second toolchain.

**What would actually make WASM win here is batching, not language choice.** 020 found
the crossover at **K≈4–16 pairs per call**: hand WASM sixteen pairs at once instead of
one, and it pulls decisively ahead, because the ~5.5 ns crossing is amortized over real
work. This experiment's solver calls `score_guess` one pair at a time — the worst
possible shape. The 1.68x was never really language-vs-language; it was one JS
formulation against a call pattern that suited neither.

The generalisable rule is **amortization**: WASM earns its bytes when the work done per
byte shipped is high enough to repay the binary's fixed overhead. At 950 bytes of
integer comparison, against JS that has been given equal effort, that repayment does not
arrive. At experiment 014's 1.1 MB SQLite leg it is not remotely in question.

### CORS demo

`serve.py` sends `Access-Control-Allow-Origin: *` (+ `Methods`/`Headers`) on
every response and answers `OPTIONS` preflight; pass `--no-cors` to omit them.
To see the actual failure mode inlining sidesteps — not just assert it —
run a page origin and a foreign origin standing in for a differently
configured CDN/host:

```bash
make run PORT=8010              # the page's own origin
python3 serve.py 8011 --no-cors # foreign origin, no CORS headers
# open http://127.0.0.1:8010/inline.html?engine=rust, set
# "Foreign-origin port" to 8011, click "Test cross-origin fetch".
```

Confirmed by hand: with `8011 --no-cors`, `fetch('http://127.0.0.1:8011/engine-rust.wasm')`
from the `8010` page throws `TypeError: Failed to fetch` (blocked). Drop
`--no-cors` on the second server and the identical fetch succeeds. In both
cases, the inline-loaded module — which never contacts port 8011 at all,
since its base64 bytes are part of the `8010` page's own same-origin assets —
works regardless. That's the honest shape of the win: inlining doesn't make
cross-origin fetches CORS-compliant, it makes the cross-origin request
unnecessary in the first place.

## Solver Strategies

The app includes an integrated solver demonstrating classic Mastermind algorithms:

| Strategy | Average | Worst | Description |
|----------|---------|-------|-------------|
| Koyama & Lai (1993) | 4.34 | 5 | Minimizes expected remaining possibilities |
| Knuth minimax (1977) | 4.48 | 5 | Minimizes worst-case remaining possibilities |
| Entropy | 4.42 | 5 | Maximizes Shannon information gain |
| Static (pairs/mono) | fails | fails | Non-adaptive, demonstrates why adaptation matters |
| Memory-1 | ~4.5 | 5 | Only remembers last guess — bounded memory |

Select a strategy from the dropdown and click "Solve" to watch it crack the code.

## REST API

The server exposes endpoints for CLI play:

```bash
# Start a new game
curl -X POST http://localhost:8010/api/new

# Make a guess (colors 1-6: R,G,B,Y,O,P)
curl -X POST http://localhost:8010/api/guess -d '{"guess":[1,1,2,2]}'
# Returns: {"blacks": 1, "whites": 0, "attempts": 1, "won": false, ...}
```

## What this builds on

- Experiment 004's static-page-delivery pattern (`python3 serve.py`, no backend
  at execution time) — same shape, no server-side compute.
- Experiment 009's native-Rust-host work — this is the browser-side counterpart:
  same language, same `wasm32` target family, different host.
