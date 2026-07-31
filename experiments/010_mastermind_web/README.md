# Experiment 010 — Mastermind, scored by WASM, in the browser

Where WASM actually shines: not another hello-world, and not a server proxy for
compute — a real, deterministic, pure scoring function running in-browser, called
directly from a click-driven UI, zero server round-trips after the initial page
load. Built on top of experiment 008's harness work (the `runtime` import
convention, and two real bugs found and fixed there while building this one — see
below) and directly motivated by `mvl-lang/mvl/examples/mastermind`, which doesn't
compile end-to-end today (its `main.mvl` is an I/O shell that needs `stdin`, which
`--backend=wasm` doesn't support — see experiment 011 for what *would* be needed).

## What's vendored, and why

`vendor/code.mvl` is `mvl-lang/mvl/examples/mastermind/code.mvl` (the PURE half of
the example — zero effects, zero extern, by the original author's own design) with
one function removed:

- **`render_feedback` — removed.** Under `--backend=wasm` it emits a call to
  `$mvl_int_to_string` (from `Feedback.blacks.to_string()`) that is never imported
  or defined anywhere in the compiled module. Not a runtime trap — a hard assembly
  failure (`wasm-tools parse` refuses the whole file: `unknown func: failed to find
  name '$mvl_int_to_string'`). The UI doesn't need it anyway: blacks/whites render
  directly as pegs (see `app.ts`), never as a formatted string.

Two more functions compile and export fine but are **unusable at runtime** — calling
either traps immediately:

- **`parse_guess`** and **`render_code`** — both compile to a body that's just
  `;; body stubbed — contained unsupported constructs` followed by `unreachable`.
  Confirmed by grep on the compiled WAT, not assumed. This is *why* the UI is
  click-to-pick colored pegs rather than a text input: `parse_guess` (the only
  function that would parse typed guesses) can't run under this backend, so the UI
  design sidesteps it entirely rather than working around it.

None of this was filed as a compiler issue yet — see "Open findings" below.

## The struct ABI (why this took real reverse-engineering)

`score_guess(secret: List[Int], guess: List[Int]) -> Feedback` returns a struct.
Reading its actual WAT body (not guessing) is how this experiment's whole runtime
fix chain in experiment 008 got started:

```wat
i32.const 16
call $_mvl_struct_alloc
local.set $__st
local.get $__st
local.get $blacks
i64.store offset=0
local.get $__st
local.get $whites
i64.store offset=8
```

`_mvl_struct_alloc`'s return value gets `i64.store`d into directly — it has to be a
real address in the shared linear memory, not an opaque JS-side handle. Experiment
008's `mvl-runtime.js` had exactly this bug (returned a handle-table index instead),
which — much bigger discovery — turned out to be the actual root cause of a crash
previously filed as [mvl-lang/mvl#2083](https://github.com/mvl-lang/mvl/issues/2083)
against the *compiler*. That issue has been corrected and closed; the fix (a real
bump allocator, `bumpAllocScratch`, plus the same fix for `_mvl_array_get` and every
string-creating function) lives in experiment 008's `mvl-runtime.js`, vendored here
unmodified. Full writeup: `experiments/008_mvl_example_wasm_harness/README.md`.

`app.ts`'s `scoreGuess()` reads the result the same way the compiled module itself
would: `DataView(memory.buffer).getBigInt64(fbPtr + 0)` for blacks,
`getBigInt64(fbPtr + 8)` for whites.

## Open finding: dead-code elimination drops string data for functions unreached from `main()`

`color_name(n: Int) -> String` compiles and exports cleanly, and its `i32.const
<ptr> / i32.const <len>` pairs for "red"/"green"/etc. are present in its body — but
the compiled module has **zero `(data ...)` segments**, so those offsets point at
nothing. Confirmed the mechanism, not just the symptom: adding a throwaway
`fn main() -> Unit ! Console { println(color_name(1)) }` to a scratch copy makes all
7 segments reappear (at different offsets, since the whole static layout shifts).
`code.mvl` is deliberately main()-less (that's the point of vendoring the pure half
of the example) — the compiler's reachability analysis for string-literal data
appears to be rooted at `main()` only, not at every WASM export, even though `pub`
functions still get correctly `(export ...)`'d regardless of that same reachability
check.

**Worked around, not silently patched over**: `scripts/patch-data-segments.mjs` runs
as part of `build.sh`, re-derives the (ptr, len) pairs directly from `color_name`'s
own compiled body (in source order — one `i32.const`/`i32.const` pair per
`if`/`else if` branch), and injects the missing `(data ...)` segments before
assembling to `.wasm`. Fails loudly (nonzero exit, no output written) if
`color_name`'s shape ever changes in a way the script's assumptions don't cover,
rather than silently writing wrong data.

## Open findings not yet filed

None of the three MVL-backend-specific findings above (`render_feedback`'s
undefined `$mvl_int_to_string`, `parse_guess`/`render_code`'s unreachable stubs, the
dropped-data-segments DCE bug) have been filed against `mvl-lang/mvl` yet — flagged
for a filing decision rather than filed unilaterally.

## The UI

Click-to-pick, not type-to-guess (see above for why). Dark theme, glowing gradient
pegs per color, animated row entry, a live attempt counter, and a win/lose overlay
that renders the actual secret via — again — a real WASM call (`color_name` on each
secret peg), not a hardcoded lookup table on the JS side. `crypto.getRandomValues`
picks the secret client-side (there's no RNG in `code.mvl` — by design, it's pure).

`app.ts` calls exactly two WASM exports: `score_guess` (the whole game) and
`color_name` (peg tooltips + the reveal text) — everything else in the vendored
module (`count_blacks`, `count_color_at_mismatch`, `parse_guess`, `render_code`) is
either an internal helper `score_guess` calls itself, or unusable per above.

## Usage

```bash
./build.sh          # mvl build --backend=wasm, patch, WAT->WASM, compile TS UI
python3 serve.py    # serves web/ at http://127.0.0.1:8010 (no COOP/COEP needed — no SharedArrayBuffer here)
```

Verified with a real headless Chromium session (Playwright, borrowed from
experiment 006's install rather than adding a new dependency here): engine loads,
palette clicks build a guess, submit calls into WASM and renders correct feedback
pegs, attempt counting and the loss/win overlay both work, "New Game" resets
cleanly, zero console errors. Confirmed via a genuine clean-room rebuild (`rm -rf
web/dist web/node_modules web/code.wasm vendor/code.wat vendor/code.wasm`, then
`./build.sh` from nothing) before every commit, not just once at the start.

## Structure

```
010_mastermind_web/
├── README.md
├── build.sh                       # mvl build -> patch data segments -> wasm-tools parse -> tsc
├── serve.py                       # static server, correct .wasm MIME type, serves from its own dir
├── scripts/
│   └── patch-data-segments.mjs    # works around the DCE bug above
├── vendor/
│   └── code.mvl                   # from mvl-lang/mvl/examples/mastermind, render_feedback removed
└── web/
    ├── index.html
    ├── style.css
    ├── app.ts                     # game logic + WASM interop
    ├── mvl-runtime.d.ts           # ambient types for the imported runtime
    ├── mvl-runtime.js             # vendored from experiment 008 (post-fix)
    └── package.json               # typescript, dev-only
    # code.wasm, dist/ are build.sh output, gitignored
```

## What this builds on

- Experiment 008's `runtime` import convention and `mvl-runtime.js` — used
  unmodified here (post-fix), not reimplemented.
- Experiment 004's static-page-delivery pattern (`python3 serve.py`, no backend at
  execution time) — same shape, no server-side compute.
