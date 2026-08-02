# Experiment 006 — Worker.terminate() as a Kill Switch

the MVL playground trusts a single mechanism to stop a runaway user program: a
5-second client-side timeout that calls `Worker.terminate()`. This experiment builds
the hostile case that mechanism is supposed to handle — a genuinely unconditional WASM
loop, no exit condition, no yield point — and finds out what `terminate()` actually
does to it, with two independent lines of evidence, not assumptions.

## The headline result

**`Worker.terminate()` does not stop a tight WASM loop immediately.** Across every run
of this experiment (manual spot-checks and the automated harness alike, both loop
variants), the loop kept executing for **~2.14 seconds after `terminate()` was
called** before it actually stopped. `terminate()` itself returns in a fraction of a
millisecond — but the underlying execution runs on for over two more seconds
regardless.

This directly refutes the premise the playground's 5-second timeout implicitly
assumes (that `terminate()` is close to instant). It doesn't invalidate the timeout —
5s still comfortably covers a ~2.1s kill delay — but "close to instant" was wrong, and
worth knowing precisely rather than assuming.

## Hypotheses

| # | Hypothesis | Status |
|---|-----------|--------|
| H1 | `Worker.terminate()` does stop WASM execution — the OS thread is actually killed, not just orphaned | **Confirmed, eventually** — see Finding 1. It does stop, but not on the timescale one might assume. |
| H2 | Termination is fast (order of milliseconds), not dependent on the loop yielding | **Refuted.** ~2,137ms, not milliseconds — three orders of magnitude slower than "fast." See Finding 1. |
| H3 | Tab CPU returns to baseline within a bounded window after `terminate()` | **Confirmed** — CPU%% drops from ~97-99%% (running) to ~0.2%% once the heartbeat freezes. Bounded, just not immediate (bounded by the same ~2.1s). |
| H4 | Termination behavior is consistent whether the loop is pure compute or includes memory allocation | **Confirmed, precisely** — both variants died at the identical 2,137ms across every run. See Finding 2. |

## Methodology — two independent proofs, not one

1. **Heartbeat freeze (primary, direct proof).** The WASM loop calls an imported
   (non-WASI) `heartbeat_tick()` function every 100,000 iterations (`loop_pure`) or
   10,000 iterations (`loop_alloc` — allocation is slower per iteration, so a smaller
   tick interval keeps time resolution comparable). That function does
   `Atomics.add()` on a shared `Int32Array` backed by a `SharedArrayBuffer`. The main
   thread — a separate JS context untouched by termination — polls that shared memory
   every 100ms. **This does not depend on the worker cooperating in any way**: reading
   shared memory works whether the writer is alive or dead. When two consecutive polls
   read the same value, the loop has genuinely stopped incrementing it — direct
   evidence of execution having halted, not an inference from a timer or a callback
   the terminated code would have to make.
2. **Process-tree CPU%% (secondary, external corroboration).** `harness.js` finds the
   headless Chromium process tree (via a unique `--user-data-dir` per run, since
   Playwright's `Browser` object doesn't expose a `.process()` API — verified
   directly, it doesn't exist on this version) and samples `ps -o pcpu=` across all
   descendant PIDs before, during, and after termination.

`SharedArrayBuffer` requires cross-origin-isolation headers
(`Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy:
require-corp`) — confirmed directly: `typeof SharedArrayBuffer` is `"undefined"` on a
page served without them, and becomes available once `web/coi_server.py` adds them. A
plain `python3 -m http.server` (used in experiments 004/005) is not enough here.

## Findings

### 1. Death takes ~2.137 seconds, remarkably consistently

| Run | Variant | Time to death |
|---|---|---|
| Manual, run 1 | pure | 2,136ms |
| Manual, run 2 | pure | 2,137ms |
| Manual, run 3 | pure | 2,134ms |
| Manual, run 1 | alloc | 2,138ms |
| Manual, run 2 | alloc | 2,137ms |
| Manual, run 3 | alloc | 2,137ms |
| Harness (clean-room) | pure | 2,137ms |
| Harness (clean-room) | alloc | 2,137ms |

Eight measurements, ≤4ms spread, both variants, across separate browser launches.
This is not measurement noise — it looks like a fixed internal interval in
Chromium's Worker/Wasm termination handling. **This experiment did not trace into
browser internals to identify the exact mechanism** — that would need instrumenting
V8/Chromium itself, out of scope here. What's reported is the external, empirically
measured, highly reproducible number: budget for **low seconds, not milliseconds**,
when treating `terminate()` as a hard deadline enforcement mechanism.

### 2. Allocation doesn't change the kill timing — H4 confirmed precisely

`loop_alloc` grows a `Vec` by 32 bytes every iteration, never freeing it — by the time
of termination it had allocated on the order of tens of megabytes (heartbeat count ×
10,000 iterations × 32 bytes). Despite that ongoing allocation pressure, it died at
the identical 2,137ms as the pure-compute loop, both in manual testing and the
automated harness. Whatever governs the ~2.1s delay is insensitive to whether the
loop allocates.

### 3. CPU corroborates the heartbeat, with a caveat on the baseline number

| Variant | CPU while running | CPU after death |
|---|---|---|
| pure | 97.3% | 0.2% |
| alloc | 98.7% | 0.2% |

Both variants peg close to a full core while running and drop to near-idle once the
heartbeat confirms death — external confirmation of the same conclusion, not just
a repeat of it. The harness also records a "baseline" CPU%% (sampled right after
browser launch, before navigation) — that number is noisy (45-55% in these runs)
because it's measuring the browser's own startup activity, not a settled idle state.
It isn't load-bearing for the finding; the meaningful contrast is running-vs-after-death,
not baseline-vs-running.

## Limitations

- The ~2.1s mechanism is reported empirically, not explained. A follow-up that
  traces into `chrome://tracing` or V8's own termination/interrupt-check
  implementation could say *why*, not just *how long*.
- Only tested on this machine's Chromium build (Playwright-bundled Chrome Headless
  Shell). Firefox/WebKit were not tested — the repo's own 002_chromium_sandbox
  experiment is Chromium-only too, so this isn't a new limitation, just an
  unaddressed one.
- The heartbeat tick interval (every 100,000 / 10,000 iterations) sets the floor on
  timing resolution. The observed consistency (≤4ms spread) is well inside that
  floor, so this isn't the limiting factor for this particular finding, but a
  much-shorter delay than ~2s could plausibly be missed at this tick granularity.

## Usage

```bash
./build.sh
./benchmark.sh              # both variants, ~10s total

# Manual:
python3 web/coi_server.py 8899
# open http://127.0.0.1:8899/index.html?variant=pure in a real tab, or:
node harness.js pure
node harness.js alloc
```

## Structure

```
006_worker_kill_switch/
├── README.md
├── package.json              # playwright — harness.js's own dependency
├── build.sh
├── benchmark.sh               # runs harness.js for both variants
├── harness.js                 # Playwright: heartbeat-freeze death proof + CPU sampling
├── rust/
│   ├── Cargo.toml
│   └── src/bin/
│       ├── loop_pure.rs       # unconditional loop {}, heartbeat every 100k iters
│       └── loop_alloc.rs      # same, + grows a Vec every iteration
└── web/
    ├── index.html             # ?variant=pure|alloc; exposes terminateWorker()/readHeartbeat()
    ├── worker.js
    ├── coi_server.py          # static server with COOP/COEP (SharedArrayBuffer requires this)
    └── package.json
    # web/vendor/, web/loop_*.wasm, node_modules/ (both locations) — build.sh output, gitignored
```
