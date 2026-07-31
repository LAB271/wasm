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

## What this builds on

- Experiment 004's static-page-delivery pattern (`python3 serve.py`, no backend
  at execution time) — same shape, no server-side compute.
- Experiment 009's native-Rust-host work — this is the browser-side counterpart:
  same language, same `wasm32` target family, different host.
