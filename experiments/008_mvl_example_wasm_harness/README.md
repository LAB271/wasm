# Experiment 008 — Standalone MVL-WASM Example Harness

A second, independent host for `mvl build --backend=wasm` output, outside a browser.
Motivated directly by experiments 004-007: this repo spent a whole session
understanding WASM execution mechanics (static-page delivery, stdout capture,
`Worker.terminate()` timing, runtime strategy) using deliberately tiny test
programs. This experiment applies that understanding to the actual question those
experiments were building toward — **does the WASM backend hold up on real,
non-trivial MVL programs**, not just hello-world-scale ones — and is built so the
same approach could be folded into `mvl-lang/mvl-playground` later as an automated
check, rather than the playground's 12 curated examples being the only proof the
WASM backend works on anything.

## The gap this closes

`mvl-lang/mvl-playground` is currently the **only** thing anywhere that can execute
`mvl build --backend=wasm` output. Confirmed directly, not assumed:

- `mvl run` doesn't accept `--backend=wasm` at all (not in its own `--help`)
- Bare `wasmtime run main.wasm` fails: `unknown import: runtime::memory has not been defined` — the compiled module expects a `runtime` import namespace (~60 hand-written functions for string/array/option/result/map operations) that is a **playground-specific convention**, not a standard WASI world. Nothing outside the playground's own JS implements it.

So "does this MVL program actually run correctly under the WASM backend" has never
been testable for anything outside the playground's 12 curated examples — which are,
by construction, the *only* ones anyone has ever run this way.

## What this harness is

- **`harness/mvl-runtime.js`** — a byte-faithful port of `mvl-lang/mvl-playground`'s
  `web/src/runtime/mvl-runtime.ts` (TS → plain JS, no logic changes — every function
  ported 1:1). This tests the actual runtime the playground ships, not a
  reimplementation of it. If `mvl-runtime.ts` changes upstream, this file needs the
  same change, or it stops being a faithful test of what the playground actually
  does.
- **`harness/run-example.mjs`** — compiles an `.mvl` file (`mvl build --backend=wasm`),
  converts WAT → WASM binary (`wasm-tools parse`, the CLI-equivalent of what the
  playground's Rust backend does server-side via the `wat` crate), instantiates
  against the ported runtime + `@bjorn3/browser_wasi_shim` (same shim experiments
  004-007 used, works identically in plain Node — no browser needed for any of
  this), and captures stdout/stderr.
- **`run-tests.sh`** — for each `test-cases/<name>/`, runs it and diffs captured
  output against `expected-stdout.txt` (captured from `mvl run main.mvl` — the
  native/Rust-backend execution, ground truth for correct behavior).

No browser, no Playwright, no headless Chromium anywhere in this experiment — a
genuinely lighter-weight testing approach than the playground's own Worker-based
execution, since none of what's being tested here (does the compiled module run
correctly against the runtime convention) actually needs a browser context.

## Test case: actor_trading

Chosen deliberately as something with real complexity, not another hello-world:
`mvl-lang/mvl/examples/actor_trading` is an order-matching engine with real actors
(`OrderBook`, `Matcher`), not the toy ping-pong of `actor_pingpong` (the only
actor-based example currently curated into the playground).

**Result: FAIL, precisely located.**

```
=== actor_trading ===
  FAIL — output diverges from mvl run (native backend)
  --- diff (expected vs actual) ---
  4,19d3
  < 
  < --- scenario 2: resting bid crossed by aggressive ask ---
  < OrderBook: ask 0 price=100 qty=10
  ... [rest of scenarios 2-3 never printed]
  --- runtime error ---
      at order_book_submit (wasm://.../wasm-function[66]:0xbbe)
      at order_book_dispatch (wasm://.../wasm-function[67]:0xc46)
      at __mvl_actor_route (wasm://.../wasm-function[75]:0xf6b)
      at __mvl_actor_pump (wasm://.../wasm-function[76]:0xfb1)
      at _start (wasm://.../wasm-function[79]:0x1091)
```

The module compiles cleanly (no warnings, all 60 `runtime` imports satisfied) and
runs correctly right up until the first real actor-to-actor message dispatch, then
traps with `memory access out of bounds` inside the compiled module's own code —
not in a call to the JS runtime.

**Ruled out before filing, not assumed:**
- Not a missing import — the crash is inside `order_book_submit`, not at a call boundary into JS.
- Not a memory-capacity issue — reproduces identically at `initial: 1` (64KB, the playground's actual default) and `initial: 64` (4MB). The module never emits `memory.grow` (`grep -c memory.grow main.wat` = 0), so more memory can't help; something computes or dereferences a wrong address.
- Not one of the three already-tracked WASM gaps (mvl#2054 extension methods, #2055 `std.env.exit`, #2056 `std.log`) — none involve actor message routing.

**Filed as [mvl-lang/mvl#2083](https://github.com/mvl-lang/mvl/issues/2083).** New bug, not a duplicate — checked all three related issues before filing.

## Usage

```bash
cd harness && npm install    # once
cd ..
./run-tests.sh                # runs every test-cases/*/, reports PASS/FAIL with diffs
```

To try a different example: copy its `.mvl` files into `test-cases/<name>/`, capture
its correct output via `mvl run main.mvl` into `test-cases/<name>/expected-stdout.txt`
(strip the compiler's own build-status lines from the top), and re-run.

## Structure

```
008_mvl_example_wasm_harness/
├── README.md
├── run-tests.sh
├── harness/
│   ├── mvl-runtime.js       # ported from mvl-playground's mvl-runtime.ts
│   ├── run-example.mjs      # compile -> WAT->WASM -> instantiate -> capture
│   └── package.json         # @bjorn3/browser_wasi_shim
└── test-cases/
    └── actor_trading/
        ├── main.mvl          # copied from mvl-lang/mvl/examples/actor_trading
        ├── types.mvl
        └── expected-stdout.txt  # captured via `mvl run main.mvl`
    # main.wat / main.wasm are run-example.mjs output, gitignored
```

## What could move into mvl-playground later

The `runtime` namespace convention and the WAT→WASM→instantiate pipeline are
identical to what the playground already does — this harness's real value if
adopted there is as a **CI check independent of the browser**: run every example a
future curator considers adding through `run-tests.sh` before it's wired into
`sync-examples.sh`, so a broken example is caught by a fast Node script instead of a
silently blank Runtime tab in a real user's browser.
