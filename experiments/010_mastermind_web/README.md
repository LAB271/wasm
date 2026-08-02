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
or `make build` for all three. `make clean` removes build output. `make help`
(also the default target) lists everything with a one-line description.

## Testing

```bash
make test           # everything below
make test-unit       # cargo test (Rust logic) + tests/wasm.test.mjs (both compiled .wasm files, in Node)
make test-browser    # tests/browser.test.mjs — real headless Chrome, both engines, full click-through
```

`test-unit` loads both compiled `.wasm` artifacts directly in Node (no browser,
no server) and checks known scoring cases plus a 200-case randomized parity
sweep between the two engines. `test-browser` launches the system-installed
Chrome via Playwright (`channel: 'chrome'` — no separate browser download),
loads the real served page for each engine, plays a full guess through the UI,
and asserts feedback pegs render correctly with zero console errors.

## Structure

```
010_mastermind_web/
├── README.md
├── Makefile                       # build-rust, build-as, build-ui, build, run, test, clean
├── serve.py                        # static server, correct .wasm MIME type, serves from its own dir
├── engines/
│   ├── rust/                       # score_guess, cargo test covers the scoring logic
│   └── assemblyscript/             # score_guess, same ABI, no host imports
├── tests/
│   ├── wasm.test.mjs               # both engines, direct WebAssembly.instantiate, in Node
│   └── browser.test.mjs            # real headless Chrome, full UI click-through
└── web/
    ├── index.html
    ├── style.css
    ├── app.ts                      # game logic + WASM interop
    └── package.json                # typescript, dev-only
    # engine-rust.wasm, engine-as.wasm, dist/ are build output, gitignored
```

## WASM Size Optimization — A Case Study

For trivial functions, WASM binary size varies dramatically by language and build
configuration. This experiment documents the journey from 16KB to 950 bytes for
the same Rust function:

| Configuration | Size | Notes |
|---------------|------|-------|
| Rust default (`std`) | 16 KB | Includes panic handling, allocator stubs, LLVM glue |
| Rust `#![no_std]` | 3.1 KB | Removes stdlib, requires custom panic handler |
| Rust `#![no_std]` + `wasm-opt -Oz` | **950 B** | Binaryen optimizer strips dead code |
| AssemblyScript | **481 B** | Designed for WASM, near 1:1 compilation |

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
