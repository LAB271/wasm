# Experiment 007 — Custom Minimal Runtime vs. Embedded Interpreter

the MVL playground doesn't embed an existing language interpreter into WASM at
all. It ships a hand-written JavaScript object (~60 functions: string/array/option/
result/map operations) as a custom `"runtime"` import namespace that the compiled WASM
module calls directly — a much lighter-weight strategy than embedding CPython
(`componentize-py`, experiment 003's Python legs) or a full Python-in-WASM runtime
(Pyodide, experiments 001/002). This experiment compares all three along artifact
size, cold start, and build complexity — gathered directly, not assumed from other
experiments' result tables (both 001's and 003's were still blank
`<!-- populated by benchmark.sh -->` placeholders as of this writing).

**This is not an apples-to-apples functional comparison.** componentize-py and
Pyodide serve the same "Hello World" JSON HTTP handler as experiments 001/003. The
custom-runtime leg does a much smaller thing — one string concatenation via a
handle-based JS shim — because that's the actual shape of what mvl-playground does
(one operation, backed by a hand-written import), not a full HTTP server. The
comparison is about runtime/artifact/complexity characteristics of three strategies
for "how does the language's behavior reach the sandbox," not identical workloads.

## Results

| Leg | Artifact size | Cold start | Hand-written runtime code | External toolchain |
|---|---|---|---|---|
| custom_runtime | 302 bytes | 0.28ms | 41 (Rust) + 37 (JS) = 78 lines | `rustc` + `wasm32-unknown-unknown` (stock, no extra install) |
| componentize-py | 17.6MB | **N/A — see Finding 2** | 0 lines (embeds CPython) | `componentize-py` PyPI package + 7-line hand-authored WIT (+ ~3,000 lines of vendored WASI world definitions, not hand-authored) |
| Pyodide | 11.9MB (core `.wasm` + stdlib zip) | 845ms | 0 lines (embeds CPython) | npm `pyodide` package |

## Hypotheses

| # | Hypothesis | Status |
|---|-----------|--------|
| H1 | Custom minimal runtime produces the smallest artifact by a wide margin | **Confirmed, dramatically** — 302 bytes vs. 11.9MB (Pyodide) vs. 17.6MB (componentize-py). ~39,000x and ~58,000x smaller respectively. |
| H2 | Custom minimal runtime has the fastest cold start | **Confirmed for Pyodide (0.28ms vs. 845ms); unresolved for componentize-py** — its cold start could not be measured in this environment (Finding 2), not because it was fast, but because it never ran. |
| H3 | The cost of "custom minimal runtime" is build/maintenance complexity, not runtime performance | **Confirmed, precisely quantified in Finding 3** — every operation needs hand-written code on both the WASM side and the JS-import side; an embedded interpreter gets its standard library for free at the cost of size and cold start. |
| H4 | componentize-py sits between Pyodide and the custom runtime on both axes | **Refuted on artifact size (componentize-py is larger, not in-between); untestable on cold start** (Finding 2) |

## Findings

### 1. The size gap is not close

302 bytes vs. multi-megabyte. This isn't "smaller" — it's a different category. The
302-byte module has no standard library, no interpreter, no string/collection
machinery of its own; every one of those things it needs, it asks the host for, one
call at a time. That's the entire trade being measured.

### 2. componentize-py's cold start could not be measured — a real environment gap, reported rather than hidden

Built successfully (`componentize-py -d wit -w proxy componentize app -o
hello-py-raw.wasm`, ~3s, 17.6MB output — this part works and the artifact size is
real). Running it via `wasmtime serve` (the exact command experiment 003's own
`python-raw/app.py` documents) fails immediately:

```
Error: component imports instance `wasi:cli/environment@0.2.4`, but a matching implementation was not found in the linker
Caused by:
    0: instance export `get-environment` has the wrong type
    1: function implementation is missing
```

This is a WASI Preview2 world-version mismatch between the locally installed
`wasmtime` (43.0.1) and whatever WASI snapshot `componentize-py`'s generated bindings
target — a real, environment-specific toolchain compatibility gap, not a bug in the
artifact itself. Tried the `python-spin` leg as an alternative runtime path (Spin
bundles its own wasmtime, decoupled from the system one) and hit a **second,
pre-existing gap**: `python-spin/` has no `wit/` directory tracked in the repo at
all, so `spin build` fails with `AssertionError: failed to read path for WIT [wit]`
before it can even try. Neither of these was introduced by this experiment; both are
reported here because gathering real numbers is what surfaced them — reused, not
duplicated, matching this experiment's own scope constraint against rebuilding
experiment 003 from scratch. Filing both as follow-up observations for whoever
next works on experiment 003, not fixed here.

### 3. Build complexity, quantified

| Leg | What you write | What you get for free |
|---|---|---|
| custom_runtime | Every operation (78 lines total for one string-concat op) | Nothing — no stdlib, no GC, no interpreter |
| componentize-py | 7 lines of WIT interface, arbitrary Python | Full CPython + stdlib, at 17.6MB and (normally) multi-second cold start |
| Pyodide | Plain Python, no interface code at all | Full CPython + stdlib, at 11.9MB core + 845ms cold start |

The custom-runtime leg's 78 lines cover exactly one operation. A real language runtime
built this way needs new hand-written code — on both the WASM side and the JS-import
side — for every additional capability (arrays, maps, options, results, ...), which is
exactly the shape of `mvl-playground`'s actual ~60-function runtime object. That
ongoing, per-feature cost is the real price of the size/speed win in Finding 1,
not a one-time cost paid once and then forgotten.

### 4. A shared, pre-existing bug found and fixed along the way

Gathering componentize-py's cold start honestly required actually trying it, not
assuming it would work — and `../001_hello_world/lib/bench.sh`'s `cold_start_ms`
(shared by every experiment in this repo, including 001, 002, 003, and this one) had
**no success/failure signal at all**. If the polled server never came up, the
function fell through and printed the *entire timeout budget* as if it were a real
cold-start measurement — silently fabricating a number rather than reporting failure.
First encountered exactly this way: componentize-py's `wasmtime serve` died
instantly, but this experiment's own first attempt still reported a plausible-looking
`12666ms` "cold start" for it, because the helper couldn't tell success from timeout.

Fixed in `lib/bench.sh` (shared, so this benefits experiments 001-003 too, should any
of their legs ever hit the same failure mode): the function now returns non-zero and
prints nothing to stdout when the timeout elapses without a successful response,
instead of silently reporting the timeout as a measurement. All three other
experiments' `benchmark.sh` scripts already use `set -euo pipefail`, so this is the
behavior they were already asking for — a failed cold-start probe will now stop the
script with a clear message instead of continuing with a fabricated number.

**Caught the same mistake a second time, one function away, before publishing.**
This experiment's own Pyodide-leg measurement initially guarded
`require_port_free 5002 ... || true` — swallowing exactly the kind of failure the
fix above exists to surface. With a stray process still bound to port 5002 from
earlier manual testing, that `|| true` let the script continue anyway: `run.sh`'s
own server failed to bind, but `curl` happily talked to the *stray* process
instead, producing a fabricated `37ms` "cold start" for a process that never
cold-started at all — the same failure shape, one guard away from the fix just
described. Removed the `|| true`; the script now stops with a clear message if the
port isn't free, rather than measuring whatever happens to already be listening.

## Usage

```bash
./benchmark.sh    # builds and measures all three legs; ~15-20s total
                  # (componentize-py's cold-start step is expected to report
                  # N/A in an environment with this wasmtime/componentize-py
                  # version combination -- see Finding 2)
```

## Structure

```
007_custom_runtime_vs_interpreter/
├── README.md
├── benchmark.sh                   # builds + measures all three legs directly
└── custom_runtime/
    ├── rust/
    │   ├── Cargo.toml              # wasm32-unknown-unknown, no WASI
    │   └── src/lib.rs              # the whole "language": one string-concat op
    └── harness/
        ├── runtime.js              # the hand-written JS runtime shim (~37 lines)
        └── measure.mjs             # Node: instantiate + one call, timed
    # rust/target/ is gitignored (build.sh-equivalent output)

# componentize-py and Pyodide legs are NOT duplicated here -- benchmark.sh
# builds/runs them in place inside ../003_wasm_compile/python-raw/ and
# ../001_hello_world/leg2a_pyodide_node/ respectively.
```
