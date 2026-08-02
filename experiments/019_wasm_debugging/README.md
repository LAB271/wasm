# Experiment 019 — WASM Debugging vs. Binary Size

[Experiment 010](../010_mastermind_web/) documented shrinking a Rust WASM module from
16KB to **950 bytes** via `#![no_std]`, `opt-level="z"`, `lto=true`, `panic="abort"`,
`strip=true`, and `wasm-opt -Oz`. Every one of those steps also destroys debuggability:
`strip=true` removes the name section, `panic="abort"` skips unwinding, `wasm-opt -Oz`
discards DWARF. That 950-byte artifact is maximally hostile to a debugger.

This experiment is the other side of that coin: **what does debuggability cost in
bytes, and what should you actually ship?** Same kind of module (fibonacci + a
deliberate panic path), same optimization recipe as 010, built across four tiers from
"fully optimized" to "full debug," measured for real — not modifying 010, just reusing
its exact flags as the size baseline.

## Tier matrix (real, measured)

| Tier | Flags | Raw | Gzip | Brotli | × tier1 |
|---|---|--:|--:|--:|--:|
| 1. Fully optimized | `no_std`, `opt-level=z`, `lto`, `panic=abort`, `strip=true`, `wasm-opt -Oz` (010's exact recipe) | 719 B | 585 B | 546 B | 1× |
| 2. Optimized + names | as tier 1, but `strip="debuginfo"` (not `strip=false` — see "surprise" below) + `wasm-opt -Oz -g` | 1,123 B | 860 B | 819 B | 1.6× |
| 3. Release + debug info | std, `opt-level=3`, `lto=false`, `panic=unwind`, `debug=true`, no `wasm-opt` | 1,500,009 B | 318,793 B | 273,858 B | 2,086× |
| 4. Full debug | std, `dev` profile (`opt-level=0`), no `wasm-opt` | 1,542,753 B | 330,734 B | 285,773 B | 2,146× |

For scale: tier1 (719B) is actually *smaller* than 010's 950B baseline — our module has
three exported functions (`fibonacci`, `trigger_panic`, `log_and_compute`) vs 010's one,
but the panic path compiles to a single `unreachable` instruction, cheaper than 010's
scoring logic. **The headline number is the tier1→tier3 jump: going from zero debug info
to DWARF costs over 2,000× in raw bytes, ~500× even after brotli.**

All sizes are real (`make size`), all modules `wasm-tools validate` clean, and tier3/4's
DWARF passes `llvm-dwarfdump --verify` with "No errors." (`make check-sections`).

### Surprise: `strip = false` is not "keep names, nothing else"

The brief's tier2 recipe was "as tier1, but strip=false." Measured, that produced a
**594KB** binary — not because of the name section (568 bytes), but because `strip =
false` also disables Cargo's post-link removal of whatever DWARF LTO happened to pull in
from the *precompiled* `core`/`compiler_builtins` sysroot rlibs. Cargo's `strip =
"debuginfo"` (a string, not a bool) is what actually means "names only" — it strips
DWARF but keeps the wasm name section. That's what tier2 above uses. This cost us a
debugging session; recorded here so nobody else pays it.

## What was verified by running vs. read in docs

**Verified by running** (all reproducible via `make test`):
- **H1 (DWARF sufficiency, partial):** tier3/tier4 carry full `.debug_info`/`.debug_line`/etc.,
  verified well-formed via `llvm-dwarfdump --verify` (`make check-sections`). Source-level
  *stepping in Chrome DevTools* itself was **not** watched — see below.
- **H2 (name section → readable traces): CONFIRMED.** Real trap captured on `trigger_panic(4)`
  under both a native wasmtime host and Node, tier1 vs tier2 (`make traces`):
  - Tier1 (stripped): `<unknown>!<wasm function 3>` (wasmtime) / `wasm-function[3]` (Node) — useless.
  - Tier2 (names only, +404 bytes over tier1): `wasm_debug_demo.wasm!trigger_panic` (wasmtime) /
    `wasm_debug_demo.wasm.trigger_panic` (Node) — the real function name, no DWARF needed.
  - Tier3/4 (DWARF) add file:line: `wasm_debug_demo::trigger_panic_impl ... at .../lib.rs:56:5`.
- **H3 (multiplier): CONFIRMED, and larger than expected.** 2,086×–2,146× raw, ~500× brotli
  (table above) — driven by DWARF for the *entire* linked std/core/compiler_builtins sysroot,
  not just our ~20 lines of source.
- **H4 (`wasmtime --profile=guest` resolves source functions): CONFIRMED, and only needs
  the name section, not DWARF.** Ran on three zero-import builds (`make profile-guest`):
  no-names → profile shows `<wasm function 1>`; with-names → `fibonacci`; with-DWARF →
  also `fibonacci` (DWARF added no extra resolution over the name section for this profiler).
- **H5 (host-imported logging, partially confirmed):** `host_log` import mechanism works
  identically under Node and a native wasmtime host, all four tiers (`make traces`). But
  *trap* stack-trace quality does **not** match across hosts: wasmtime's embedding API
  (backed by `addr2line`) demangles Rust symbols and resolves file:line from DWARF; Node/V8
  prints raw v0-mangled symbols (e.g. `_RNvNtCs3O6bguQwcd4_4core9panicking9panic_fmt`) with
  no file:line even when DWARF is present. Same binary, same trap, different debuggability
  per host — H5 as stated ("works identically") is **rejected** for stack traces, confirmed
  only for the plain logging import.

**Read in docs, not run:**
- Chrome DevTools "C/C++ DevTools Support (DWARF)" extension: name and install link
  confirmed via [developer.chrome.com/docs/devtools/wasm](https://developer.chrome.com/docs/devtools/wasm)
  (accessed 2026-08-02), install via `https://goo.gle/wasm-debugging-extension`. Source-level
  stepping itself was not watched in this session — no interactive browser available to this
  agent. Sections present + well-formed is verified (above); stepping is not.
- `wasmtime --profile=guest` CLI flag semantics: confirmed against
  [docs.wasmtime.dev/examples-profiling-guest.html](https://docs.wasmtime.dev/examples-profiling-guest.html)
  (accessed 2026-08-02) — default output path/interval — then verified live output ourselves (H4 above).

## Manual DevTools verification (procedure, not yet performed)

1. Install **C/C++ DevTools Support (DWARF)** from `https://goo.gle/wasm-debugging-extension`.
2. `make serve`, open `http://127.0.0.1:8019/`, select **tier4 (full debug)**.
3. Open Chrome DevTools → Sources. With the extension active, the wasm module should
   appear with `module/src/lib.rs` as a real source file, not disassembly.
4. Set a breakpoint on `LUT[n as usize]` in `trigger_panic_impl` (lib.rs:56).
5. Click "trigger_panic(4) — traps". Expect: execution pauses at the breakpoint,
   variables (`n`, `LUT`) inspectable in the Scope pane, Call Stack shows real frames.
6. **Not yet observed by this agent** — this session had no interactive browser. Mark
   step 5's outcome "sections present, manual verification pending" until someone does it.

## Ship recommendation

| Environment | Tier | Byte cost over tier1 |
|---|---|---|
| **Production, size-sensitive** (edge/browser, cold-start matters) | Tier 1 (fully optimized) | baseline |
| **Production, size-tolerant** / anywhere you want real stack traces without DWARF's cost | Tier 2 (optimized + names) | +404 B raw (+1.6×) — cheap insurance |
| **Staging / pre-prod** | Tier 3 (release + debug info) | +1.5MB (+2,086×) — full DWARF, still release-optimized codegen |
| **Local dev** | Tier 4 (full debug) | +1.54MB (+2,146×) — DWARF + unoptimized codegen, fastest builds |

**Concretely: always ship tier2's `strip="debuginfo"` (not `strip=true`) in production.**
The name section costs ~400 bytes and is the difference between an actionable stack trace
and `wasm-function[N]`. Reserve full DWARF (tier3/4) for environments where you can afford
megabytes, and remember it only pays off in a host that resolves it (wasmtime's native
embedding did; Node/V8's raw traces did not, in this test).

## Stretch goal not attempted

Spin's OpenTelemetry exporter needs a local collector (containerized) — skipped per the
brief's explicit stretch-goal carve-out. Untested, future work.

## Structure

```
019_wasm_debugging/
├── README.md
├── Makefile              # build, test, check-sections, traces, profile-guest, size, serve, clean
├── build.sh              # builds all 4 tiers + 3 zero-import profiling variants + native host
├── module/               # the Rust test crate (fibonacci, trigger_panic, log_and_compute)
├── host/                 # native wasmtime embedding: satisfies host_log, reports traps
├── tests/run_wasm.mjs    # Node-side counterpart to host/ — same checks, JS host
├── scripts/
│   ├── check_sections.sh   # H1: wasm-tools objdump + llvm-dwarfdump --verify, all tiers
│   ├── capture_traces.sh   # H2 + H5: real trap traces + host-log, wasmtime + Node
│   └── profile_guest.sh    # H4: wasmtime --profile=guest name resolution
├── web/index.html        # manual DevTools verification harness (see above)
└── output/               # tier*.wasm + profiling_*.wasm build artifacts (committed, like 012's)
```

## Suggested root README row

| [019](experiments/019_wasm_debugging/) | wasm_debugging | done | Debuggability vs. binary size — DWARF/name-section cost across 4 tiers, 010's other side |
