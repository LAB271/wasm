# 020 — Collections ABI: how strings, lists, maps and sets cross the boundary

**Kind: Mechanism explainer** (see root README "How to read these"). The job here is to
show *how each convention works and what it costs*, with numbers good enough to make the
tradeoff legible. Every number below was produced by running the code in this directory;
none is illustrative. But this is not held to benchmark-grade rigour on every cell — where
a number is derived rather than measured, it says so.

## The problem

WebAssembly core has `i32`, `i64`, `f32`, `f64`, plus `v128` (SIMD) and `funcref`/`externref`.

> **Scope, and a Wasm 3.0 caveat.** That list describes the core value types, and
> **Wasm 3.0 (completed 2025-09-17) adds WasmGC — real `struct` and `array` heap
> types** — so "WebAssembly has no aggregates" is no longer true of the
> *specification*.
>
> It is still true of every toolchain this repo targets, and not by a narrow
> margin. Checked on this machine:
>
> | Language | wasm targets offered | How collections are actually stored |
> |----------|---------------------|-------------------------------------|
> | Rust | 6 (`wasm32-unknown-unknown`, `wasm32-wasip1/2`, …) — **none WasmGC** | linear memory, no runtime GC |
> | Go | `js/wasm`, `wasip1/wasm` — **no WasmGC** | its own GC compiled into the module |
> | AssemblyScript | — | **TLSF allocator + its own incremental GC**, in linear memory |
> | Python | via Pyodide / componentize-py | CPython's own refcounting, in linear memory |
>
> Every one of them flattens collections into bytes in linear memory. So the six
> conventions below are not a legacy artifact — they are what you deal with in
> Rust, Go, Python and AssemblyScript today, and there is no WasmGC target to
> switch to in any of them.
>
> WasmGC is being taken up by a different set of languages — Kotlin/Wasm, Dart,
> Java via J2CL, OCaml, Scheme — where aggregates become native types and the
> interesting cost moves from marshalling to GC interaction. That is a real
> experiment, but it needs a toolchain none of the above provides, so it is out of
> scope here rather than merely unmeasured.
That is the entire type system a function signature can use.

What it has **no concept of** is aggregates. There is no string. No list. No map. No set.
Linear memory is a flat byte array with no structure the runtime knows about, and every
collection that crosses the boundary is a **convention somebody invented** — where the bytes
live, how long they are, who allocated them, who frees them, and what encoding they are in.
Different toolchains invented different conventions, incompatibly.

This experiment documents and measures six of those conventions across all four collections.

## Headline — the decision table

Given a collection and a situation, use this. Every row is backed by a measured cell below.

| You have… | Use | Why (measured) |
|---|---|---|
| **A set over a bounded integer domain** | **Bitset** (`u64` words) | 9.7–16.5x faster than sorted+binary-search in *every* wasmtime leg (6.5x under Node), and copies fewer bytes. Not close. |
| **A homogeneous numeric list** | ptr+len over linear memory, any toolchain | Marshalling is 1.5–7% of total. The bytes already are the representation; the strategy barely matters. |
| **Strings, wasmtime host, hot path** | Rust manual ptr+len (UTF-8) | 197 µs vs 322 (AssemblyScript), 796 (Component Model), 1,498 (`externref`) for the same 2,000 strings. |
| **Strings, JS host** | AssemblyScript, or accept `TextEncoder` | AS's UTF-16 matches JS's; Rust+wasm-bindgen spends **92% of its string time** in the encode. |
| **A map queried once** | Sorted k/v pairs + binary search | Slower per query than a guest-side hash map (217 vs 80 µs), but it has no build cost, allocates nothing, and keeps `HashMap`/`HashSet` out of the binary (−13,677 B). |
| **A map queried many times** | Build guest-side once, keep an integer handle | 63 µs vs 217 µs re-serialising per call — 3.4x, and the gap grows with query count. |
| **A collection you cannot or will not copy** | `externref`, host-side | **Zero bytes copied**, but never fastest here. Closest on maps: 225 µs, 6th of 9 and within 4% of hand-rolled binary search, because 4,000 lookups reach only a handful of the map's 1,000 entries. |
| **Anything the guest iterates element-by-element** | **Not `externref`** | 5.3–78x slower than copying. One host call per element, at 20–48 ns each. |
| **A public interface you don't own both sides of** | Component Model / WIT | 13 declarative lines of glue vs 61–83 hand-written. Costs ~330 ns per call. Pay it at coarse granularity. |

**The one-line version:** the cost of a collection crossing WASM's boundary is almost never
the bytes. It is (a) the *encoding* for strings, (b) the *number of crossings* for anything
element-wise, and (c) the *representation you chose* for sets — and only rarely the copy.

## Hypotheses

| # | Hypothesis | Verdict from measured data |
|---|---|---|
| H1 | Bytes copied is the dominant marshalling cost | **Refuted.** Copying 400 KB into linear memory costs 5.6–28 µs — 1.5–7% of the total. Per-*call* and per-*element* costs dominate everywhere. |
| H2 | AssemblyScript's UTF-16 strings cost ~2x the bytes of Rust's UTF-8 | **Partly.** 1.393x on a mixed corpus (70% ASCII scalars), not 2x — 4-byte UTF-8 scalars are 4 bytes in UTF-16 too. Marshal time 1.9x. |
| H3 | The Component Model's canonical ABI is competitive with hand-rolled ptr+len | **Refuted on per-call cost, confirmed on per-byte cost.** 330 ns/call vs 11 ns (30x), but its *bulk copy* is the fastest measured (8.5 µs for 400 KB). |
| H4 | `externref` avoids marshalling and is therefore cheaper | **Refuted.** Zero bytes copied and never fastest: 3.6x (maps), 5.3x (lists), 7.6x (strings), 77.6x (sets) slower than the best copying strategy. It closes the gap only in proportion to how few elements the guest touches. |
| H5 | For small integer domains a bitset beats every alternative | **Confirmed, and by more than expected.** 9.7x (WAT), 15.1x (Rust), 16.1x (Component), 16.5x (AssemblyScript), 6.5x (wasm-bindgen/Node). |
| H6 | A hash map in the guest always beats binary search over sorted pairs | **Refuted — it depends on the toolchain's string type.** True in Rust (80 vs 217 µs). *False* in AssemblyScript (282 vs 167 µs), because building `Map<string,u32>` forces a UTF-8→UTF-16 transcode per key that byte-wise binary search skips entirely. |

## The six strategies

| # | Strategy | Host used | Where the convention comes from |
|---|---|---|---|
| 1 | Hand-written WAT | wasmtime | You invent it. `guests/wat/collections.wat` — 1,721 B for all four collections. |
| 2 | Rust, manual `alloc`/ptr+len | wasmtime | You invent it, in Rust. This is what everything else generates. |
| 3 | Rust + wasm-bindgen | **Node** | Generated. 234 lines of JS glue you ship. |
| 4 | AssemblyScript | wasmtime | The AS runtime's own object model: UTF-16 strings, 20-byte managed header. |
| 5 | Component Model / WIT | wasmtime (component API) | **Standardised.** The canonical ABI is the only non-ad-hoc answer here. |
| 6 | `externref` handles | wasmtime | Don't marshal at all. The module has *no memory*. |

Leg 3 runs under Node because wasm-bindgen emits a JS module — that is a property of the
strategy, not a harness shortcut, and its numbers are **not cross-comparable** with the
wasmtime legs. Its marshal/compute split, bytes copied and glue size are.

## Workload, parity, and benchmark hygiene

**Read this before reading any table.** Issue #52 in this repo documents a bias that
invalidated a published finding: 008's harness measured variants sequentially in one
process and *whichever ran first was ~1.3x faster regardless of what it was*, which forced
the retraction of a `-Oz` vs `-O3` conclusion.

What this experiment does instead:

- **One fresh OS process per (leg, op) cell.** No two variants are ever compared inside one
  process, so there is no shared tier-up budget, JIT state or allocator history to bias.
- **The whole matrix runs twice, in forward and reverse leg order** (`./run.sh both`), and
  the report prints both columns side by side. Across 40 cells the forward/reverse ratio has
  **median 1.00, range 0.85–1.19**, with the deviations distributed in both directions and
  not clustered on the legs that ran first. That is the evidence the scheme worked; the
  bias 008 hit would show as a systematic one-directional skew.
- **A burn-in is discarded before each pass.** An earlier run *without* one showed the first
  six recorded cells 1.15–1.55x slow regardless of which leg they were — a machine-level
  warm-up effect (CPU frequency ramp / page cache), distinct from the in-process bias of
  issue #52. Three discarded cells removes it. This is recorded here rather than quietly
  fixed, because "we found a second, different ordering effect" is itself the finding.
- **Parity is asserted before anything is timed.** Every leg computes the same u64 checksum
  over the same bytes, and a mismatch is a hard error, not a warning. All 34 comparable
  cells agree bit-for-bit: strings `0xbf324d0b32ec`, lists `0x29089eecf80e43a2`,
  maps `0x7d00003f4611c`, sets `3993`. `make test` re-checks this.
- **Checksums are threaded out of every timed loop** and printed, so nothing can be
  dead-code-eliminated.
- **Medians of 9 rounds after 3 warmups**, with observed min–max reported alongside.

The checksum is FNV-1a over **Unicode scalar values** (not bytes), specifically so a UTF-8
leg and a UTF-16 leg cannot pass by accident — each has to actually decode its own encoding.

The workload is generated once by the Rust host and **dumped to disk** (`output/workload/`)
so the Node leg reads byte-identical input rather than a reimplemented generator:

| Collection | Size | Notes |
|---|---|---|
| Strings | 2,000 strings, 47,947 code points | Mixed 1/2/3/4-byte UTF-8; 70% ASCII scalars. 73,731 B UTF-8, 102,694 B UTF-16. |
| List | 100,000 `u32` = 400,000 B | |
| Map | 1,000 sorted string keys (16 B each) → `u32`, 4,000 probes | Half hits, half misses. |
| Set | 3,993 members in domain 0..65,536, 65,536 probes | Bitset needs 1,024 `u64` words = 8,192 B. |

Three phases are timed **as separate whole loops**, never with per-item timestamps:
`marshal` (get the data into the guest's world), `call` (invoke with the data already
resident), `total` (the realistic combined loop). Because they are three independent
timings, `marshal + call` does not exactly equal `total`; where a cell shows `total` below
`call`, the marshal share is smaller than the run-to-run variation.

Environment: Apple Silicon arm64, macOS 26.6, rustc 1.96.0, wasmtime crate **47.0.3**,
wasm-tools 1.245.1, AssemblyScript 0.28.20, wasm-bindgen 0.2.126, Node v26.5.0.

---

## Foundation: what one crossing costs

Every table after this is easier to read with this one in hand. 2,000 calls carrying a
single-code-point argument — no marshalling, no work.

| Leg | total µs | **ns per call** | spread |
|---|---:|---:|---|
| Rust manual (wasmtime) | 21.7 | **10.8** | 21.5–21.9 |
| Hand-written WAT (wasmtime) | 26.0 | **13.0** | 23.5–26.1 |
| AssemblyScript (wasmtime) | 35.7 | **17.9** | 29.7–39.1 |
| wasm-bindgen (Node/V8) | 86.4 | **43.2** | 73.6–101.9 |
| **Component Model, `string` arg** | **665.7** | **332.9** | 624.8–685.0 |
| **Component Model, `list<u32>` arg** | **659.0** | **329.5** | 625.6–677.9 |

**A component call costs ~30x a core-module call on this host.** The obvious explanation —
"it's the string path calling `cabi_realloc`" — is wrong, and that is why the second row
exists: a 1-element `list<u32>` costs the same 330 ns as a 1-character string. The overhead
is fixed per component call, not per allocation and not string-specific.

Scope of that claim: measured through wasmtime 47.0.3's *typed* component API. It is a
property of this host at this version, **not** something the canonical ABI mandates. What
generalises is the shape — the Component Model's cost is per-call, so amortise it over
coarse-grained calls and the 330 ns disappears into the noise (see the list and set tables,
where the component leg is the *fastest* measured).

For contrast, [016](../016_ffi_assemblyscript/) measured a *scalar* host import at ~5 ns
(wasmtime 36). Crossing cost is not one number; it depends entirely on what the signature
carries.

---

## Strings

> Builds on [013](../013_unicode_strategies/), which frames the *other* string question —
> whether to embed Unicode tables or delegate to the host for operations like case mapping
> and grapheme counting. 013's own results tables in its README are still unpopulated
> placeholders as of this writing. **This section deliberately does not re-run 013.** It
> asks the ABI question 013 does not: what does it cost to get the string across at all,
> before any Unicode operation happens?

**The cost is encoding, not size.** Every leg receives the same 2,000 strings and returns
the same checksum over the same 47,947 Unicode scalars.

| Leg | bytes copied | marshal µs | compute µs | total µs | spread (total) |
|---|---:|---:|---:|---:|---|
| Rust manual (UTF-8) | 73,731 | 51.5 | 120.4 | **196.6** | 192.5–205.4 |
| Hand-written WAT (UTF-8) | 73,731 | 41.7 | 248.5 | 295.2 | 291.7–304.5 |
| AssemblyScript (UTF-16) | **102,694** | 97.2 | 241.3 | 322.6 | 312.0–332.7 |
| Component Model (UTF-8) | 73,731 | 694.0 | 102.2 | 796.2 | 786.6–815.8 |
| `externref` (host-side) | **0** | 121.7 | 1,347.5 | **1,498.0** | 1,438.5–2,239.5 |
| wasm-bindgen — *Node, not comparable* | 73,731 | 448.8 | 38.6 | 487.5 | 446.1–544.6 |

### Who encodes, and into what

| Strategy | In-memory encoding | Who transcodes |
|---|---|---|
| WAT / Rust manual | UTF-8, host-written | Host, if its strings aren't already UTF-8 |
| wasm-bindgen | UTF-8 | JS glue, per call, via `TextEncoder` — JS strings are UTF-16 |
| AssemblyScript | **UTF-16**, length-prefixed | *Nobody*, when the host is JS. Our wasmtime host, holding UTF-8, pays it. |
| Component Model | UTF-8 (`string-encoding=utf8` in the lift, verified below) | The canonical ABI, inside the call |
| `externref` | Whatever the host already had | Nobody — but then every code point is a host call |

**UTF-16 costs 1.393x the bytes here, not 2x.** The naive "UTF-16 doubles it" intuition only
holds for ASCII. On this corpus (70% ASCII scalars, the rest spread over 2-, 3- and 4-byte
UTF-8) the ratio is 1.393, because 4-byte UTF-8 scalars are also 4 bytes as UTF-16 surrogate
pairs. Marshal time is 1.9x (97.2 vs 51.5 µs), worse than the byte ratio, because the host
has to transcode rather than `memcpy`.

**AssemblyScript's advantage is invisible in this table, and that is the point.** Our host is
wasmtime holding UTF-8, so AS pays a transcode Rust doesn't. Change the host to JS and the
sign flips.

The Rust↔JS half of that flip *is* measured here: the wasm-bindgen row isolates it, and
**448.8 of its 487.5 µs — 92% — is the encode**, with the FNV loop over the same 47,947
scalars costing only 38.6 µs. The AS↔JS half is **inferred, not measured** — this experiment
is server-side only and has no AssemblyScript-under-Node leg — but it follows directly: JS
strings are UTF-16 and AS strings are UTF-16, so the transcode that dominates the
wasm-bindgen row has nothing to do.

Neither encoding is better. They are bets on who your host is, and the bet costs about 2x
the marshalling time when you lose it.

### AssemblyScript's object layout, verified by running it

`make probe` (`js/as_layout_probe.mjs`) allocates an AS `string` from the host and reads the
header back, rather than citing the docs:

```
  ✓ ptr is 16-byte-aligned data pointer (not header)
  ✓ rtSize at ptr-4 equals 10 bytes
  ✓ guest's own rtSize read agrees with the host's
  ✓ UTF-16 code units (5) != code points (4)
  ✓ str_stats decoded 4 code points
```

`__new(byteLength, idof<string>())` returns a pointer to the **data**, and the object's byte
length lives as a `u32` at `ptr - 4`. So a host writing an AS string must (1) call into the
guest to allocate, (2) write UTF-16LE at the returned pointer, and (3) never touch `ptr-4`
itself. AssemblyScript's documentation puts the full managed header at 20 bytes below the
payload with `rtId` at −8 and `rtSize` at −4
([assemblyscript.org/runtime.html](https://www.assemblyscript.org/runtime.html), accessed
2026-08-02); this probe verifies the `rtSize` field only, which is the one the ABI needs.

Also note what the probe's test string exposes: `"hé日👍"` is 4 code points, 5 UTF-16 code
units and 10 bytes in *both* encodings. Code points, code units and bytes are three different
numbers, and a ptr+len ABI has to say which one `len` is. Ours says UTF-8 bytes for the Rust
and WAT legs, UTF-16 code units for AssemblyScript.

### Returning a string: multi-value, or a scratch return pointer?

Both, and one binary contains both. `make disasm`:

```
rustc core export (scratch return pointer):
  (func $str_upper_ascii (;25;) (type 8) (param i32 i32 i32)
after wasm-bindgen post-processing (multi-value shim):
  (export "str_upper_ascii" (func $"str_upper_ascii multivalue shim"))
```

`fn str_upper_ascii(s: &str) -> String` lowers to three `i32` parameters and **no result**:
the first parameter is a caller-supplied return area into which the guest writes `[ptr, len]`.
wasm-bindgen then post-processes the module and injects a literal function named
`"str_upper_ascii multivalue shim"` of type `(param i32 i32) (result i32 i32)`, so the JS side
receives a real two-element return. (An earlier draft of this README asserted wasm-bindgen
uses `__wbindgen_add_to_stack_pointer` for this — grepping the generated JS found zero
occurrences. It doesn't, at 0.2.126.)

The manual leg exports both spellings so you can see the choice bare:
`str_upper_ascii_packed` returns one `i64` with `ptr<<32|len` (works with no proposals at
all, caps you at 4 GB memory and 4 GB strings), and `str_upper_ascii_retptr` takes the
scratch slot as a hidden first argument.

**Ownership**: in the manual leg the returned buffer is guest-owned and leaked until the host
calls `dealloc(ptr, len)`. There is no other protocol, nothing enforces it, and forgetting is
a silent leak. The Component Model is the only leg here where this is specified rather than
agreed: the lift for `str-upper-ascii` carries a `post-return`, which the disassembly shows —

```
(func $str-upper-ascii (canon lift (core func $str-upper-ascii) (memory $memory)
      (realloc $cabi_realloc) string-encoding=utf8 (post-return $cabi_post_str-upper-ascii)))
```

— and none of the value-returning-`u64` exports do, because they allocate nothing.

---

## Lists

**Homogeneous numeric is the good case, and the numbers say the strategy barely matters.**
100,000 `u32`, 400,000 bytes, one crossing.

| Leg | bytes copied | marshal µs | compute µs | total µs | marshal share |
|---|---:|---:|---:|---:|---:|
| Component Model | 400,000 | **8.5** | 407.0 | 415.5 | 2.0% |
| Hand-written WAT | 400,000 | 21.7 | 408.3 | 403.4 | 5.4% |
| AssemblyScript | 400,000 | 28.0 | 442.1 | 398.1 | 7.0% |
| Rust manual | 400,000 | 25.5 | 415.8 | 458.2 | 5.6% |
| `externref` | **0** | 21.8 | 2,024.5 | **2,108.2** | — |
| wasm-bindgen — *Node, not comparable* | 400,000 | 5.6 | 377.8 | 383.4 | 1.5% |

Marshalling 400 KB costs **5.6–28 µs**, i.e. 0.014–0.070 ns per byte — at the low end that is
roughly `memcpy` bandwidth, which is exactly what it is. Compute (an FNV-1a chain, ~4.1 ns per
element) is 93–98.5% of every non-`externref` cell. This is the same conclusion
[008](../008_js_vs_wasm_crossover/) reached from the JS side, where marshalling a
`Float64Array` of 2M elements cost ~0.2 ms and it called flat numeric arrays "the easy,
unambiguous win case." Nothing here contradicts it; this extends it to five more toolchains
and a native host.

Note which leg is *fastest* at marshalling: the Component Model, at 8.5 µs. Its canonical ABI
lowers `list<u32>` to a single bulk copy into a `cabi_realloc`'d buffer, and 330 ns of
per-call overhead is 0.08% of a call this size. **The Component Model's cost is per call, so
a big list is precisely where you don't notice it.**

### How you'd actually write it

| Strategy | The list part, in practice |
|---|---|
| WAT | `alloc(n*4)`, host `memory.data_mut()[p..].copy_from_slice()`, guest loops `i32.load` at `p + i*4`. |
| Rust manual | Same, plus `std::slice::from_raw_parts(ptr as *const u32, len)` — one `unsafe` line and you have a real slice. |
| wasm-bindgen | `fn f(xs: &[u32])`. Glue emits `passArray32ToWasm0`: one `malloc` + one `TypedArray.set`. |
| AssemblyScript | Either raw `load<u32>` over a host-filled `ArrayBuffer` (what we do), or hand-build a `Uint32Array` object header (`buffer`, `dataStart`, `byteLength`) — the AS loader's job. |
| Component Model | `fn f(xs: Vec<u32>)`. Nothing else. |
| `externref` | `vec_len(ref)` then `vec_get_u32(ref, i)` — **don't**, see below. |

**Heterogeneous lists (AoS→SoA) are out of scope here** — 008 measured that directly and
found AoS→SoA extraction the most expensive marshalling step in its matrix (3.5–4.3 ms for
2M points, vs ~0.2 ms for a flat float array). The generalisation that matters for this
experiment: a list of structs has no good ptr+len spelling, so you either transpose to
parallel arrays host-side (008's approach), or you describe it in WIT as `list<record>` and
let the canonical ABI lay out the fields for you — which is the *only* strategy here that
gives you a defined layout for a record without inventing one.

---

## Maps

**There is no map in the core types these toolchains emit.** Not "there is an awkward one" — there is no aggregate
type at all, no key/value instruction, nothing. There is also no default convention. Every
option below is something a person chose.

1,000 sorted string keys → `u32`, 4,000 probes (half hits).

| Leg | strategy | bytes copied | marshal µs | compute µs | total µs |
|---|---|---:|---:|---:|---:|
| Rust manual | **build guest-side once, integer handle** | 104,016 | 21.1 † | 57.3 | **63.5** |
| Rust manual | `HashMap` rebuilt per call | 104,016 | 6.9 | 73.5 | 79.9 |
| AssemblyScript | sorted pairs + byte-wise binary search | 104,016 | 6.4 | 148.2 | 166.6 |
| Hand-written WAT | sorted pairs + binary search | 104,016 | 7.4 | 220.8 | 208.1 |
| Rust manual | sorted pairs + binary search | 104,016 | 6.3 | 207.3 | 216.8 |
| `externref` | **host-side map, zero copy** | **0** | 55.3 | 161.8 | 225.2 |
| AssemblyScript | `Map<string, u32>` rebuilt per call | 104,016 | 6.4 | 270.3 | 281.9 |
| Component Model | `list<tuple<string, u32>>` | 124,000 | 161.2 | 164.6 | 325.8 |
| wasm-bindgen — *Node, not comparable* | `Vec<String>` | 124,000 | 492.0 | 90.6 | 582.6 |

† `marshal` for the handle variant includes the one-off build; `call` is the amortised query.

### The three real options, stated plainly

**A. Serialize to sorted k/v pairs.** You invent a wire format. Ours (`svec`) is
`u32 count | u32 offsets[count+1] | UTF-8 blob` plus a parallel `u32` value array — 15 lines
of encoder in the host, 25 lines of WAT accessors in the guest. No allocation, no build cost,
`O(log n)` per probe, and no `HashMap` in the binary. 217 µs.

**B. Build the map in linear memory guest-side.** Two sub-cases, and the difference between
them is the whole story:

- *Rebuild per call* (80 µs): pays a full `HashMap` construction for one batch of probes,
  and still beats binary search 2.7x because hashing a 16-byte key once is cheaper than the
  ~10 string comparisons a binary search over 1,000 keys needs.
- *Build once, keep an integer handle* (**63 µs, the fastest cell**): the guest becomes
  stateful; the host gets back a `u32` it stores and passes to `map_query`. This is an
  `externref` in disguise, with the guest as the owner instead of the host. 3.4x better than
  re-serialising, and the gap widens with every extra query.

**C. Keep it host-side behind an `externref`.** 225 µs, **zero bytes copied** — 6th of the nine
cells, 3.6x the guest-handle option but within 4% of hand-rolled sorted binary search. This is
the closest `externref` comes to winning anywhere in this experiment, and it is close precisely
because the guest touches so little: 4,000 lookups against a 1,000-entry map, rather than
walking every element. Compare the set section, where the same strategy is 78x worse.
It is the right choice when copying is not an option — the map is huge, lives elsewhere, or is
a live host resource — not when it is merely inconvenient.

**D. Component Model / WIT.** There is no `map` in WIT either, but there *is* a canonical way
to spell one: `list<tuple<string, u32>>`. 326 µs, of which 161 µs is lowering. That is
32 ns per string element — the canonical ABI has to materialise 5,000 heap-allocated guest
strings through `cabi_realloc`, which is genuinely more work than blitting a pre-packed blob.
What you buy is the only spelling in this table that a *different* language's guest could
consume without reading your README.

### The finding that surprised us: hash-vs-sorted inverts by toolchain

| | sorted + binary search | hash map | winner |
|---|---:|---:|---|
| Rust manual | 216.8 µs | 79.9 µs | **hash, 2.7x** |
| AssemblyScript | 166.6 µs | 281.9 µs | **sorted, 1.7x** |

Rust's `HashMap<&str, u32>` borrows straight out of the UTF-8 blob — building it allocates
nothing per key. AssemblyScript's `Map<string, u32>` cannot: an AS `string` is UTF-16, so
every one of the 1,000 keys and 4,000 probes must be **transcoded from the host's UTF-8 and
heap-allocated** before it can be hashed. Byte-wise binary search skips all of that and never
constructs a single AS string, which is why the *lower-level* option wins in the
*higher-level* language — and why AS's byte-wise binary search (166.6 µs) also beats Rust's
`str`-comparing one (216.8 µs).

This is the same UTF-16 property as the strings section, surfacing a second time and in the
same direction: with a UTF-8 host, every AssemblyScript API that wants a real `string` is a
transcode. Under a JS host the sign flips for both.

`Vec<String>` in wasm-bindgen is worse still, and not for the reason we assumed. Verified in
the generated `pkg/collections_bindgen.js`: `passArrayJsValueToWasm0` puts each JS string into
the **externref table** and writes the table index into linear memory; the UTF-8 encode
happens lazily later, when the guest calls back out through the `__wbindgen_string_get`
import. So a `Vec<String>` argument is `2n` boundary crossings plus `n` externref-table slots,
not one bulk copy — 492 µs of marshalling for 5,000 strings.

---

## Sets

**A set is a map minus the values — except for the one case that changes everything.** 3,993
members drawn from the domain 0..65,536; 65,536 probes.

| Leg | strategy | bytes copied | marshal µs | compute µs | total µs | vs bitset |
|---|---|---:|---:|---:|---:|---:|
| Component Model | **bitset** `list<u64>` | 270,336 | 4.4 | 26.8 | **31.2** | 1.0x |
| Rust manual | **bitset** | 270,336 | 15.5 | 25.9 | **40.9** | 1.0x |
| AssemblyScript | **bitset** | 270,336 | 16.6 | 39.2 | 54.7 | 1.0x |
| Hand-written WAT | **bitset** | 270,336 | 15.2 | 35.4 | 56.1 | 1.0x |
| Hand-written WAT | sorted + binary search | 278,116 | 17.1 | 625.2 | 546.4 | **9.7x** |
| Rust manual | `HashSet` per call | 278,116 | 14.5 | 545.1 | 589.4 | 14.4x |
| Rust manual | sorted + binary search | 278,116 | 17.1 | 623.8 | 617.5 | **15.1x** |
| AssemblyScript | sorted + binary search | 278,116 | 17.6 | 796.4 | 903.9 | **16.5x** |
| AssemblyScript | `Set<u32>` per call | 278,116 | 20.3 | 876.7 | 853.5 | 15.6x |
| Component Model | sorted + binary search | 278,116 | 4.6 | 496.6 | 501.2 | **16.1x** |
| `externref` | host-side `HashSet` | **0** | 17.1 | 3,140.3 | **3,172.9** | **77.6x** ‡ |
| wasm-bindgen — *Node* | **bitset** | 270,336 | 5.9 | 69.7 | 75.6 | 1.0x |
| wasm-bindgen — *Node* | sorted + binary search | 278,116 | 4.7 | 484.9 | 489.6 | 6.5x |

‡ Ratios compare each leg against *its own* bitset row; the `externref` leg has no bitset, so
it is measured against the fastest bitset overall (Rust manual, 40.9 µs).

**For a bounded integer domain, use a bitset. It is not a close call and it does not depend
on your toolchain** — every leg, including the ones that are slow at everything else, lands
between 31 and 76 µs, and every non-bitset alternative lands between 490 and 904. The spread
across strategies (16x) is far larger than the spread across toolchains (2.4x).

Why it wins is not clever:

```wat
;; membership test, whole thing
(i64.and (i64.shr_u (i64.load (i32.add $words (i32.mul $w (i32.const 8))))
                    (i64.extend_i32_u (i32.and $x (i32.const 63))))
         (i64.const 1))
```

One load, one shift, one mask — all MVP instructions, present since WebAssembly 1.0. No
comparison chain, no hash, no allocation, no branch. **0.40 ns per probe against 9.5 ns** for a
12-deep binary search over the same members.

**And it copies fewer bytes**, which is the counter-intuitive part: 1,024 `u64` words cover
the entire 65,536-element domain in 8,192 B, whereas the sorted array needs 4 B per member
(15,972 B for only 3,993 of them). The bitset is denser here at **6.1% density** — one bit
per domain element beats four bytes per member whenever density exceeds 1/32, i.e. about 3%.
Below that, sorted wins on size; it still loses on speed at this probe count.

**Where the bitset does not apply:** unbounded or sparse domains (`u64` keys, UUIDs), string
sets, and any domain you don't know in advance. Then it is the map story minus values — sorted
+ binary search if you query once, guest-side `HashSet` behind a handle if you query often.

**`externref` is the wrong tool for a set**, by 78x. 65,536 probes means 65,536 host calls at
48 ns each; the entire bitset alternative finishes in the time ~850 of those calls take.

---

## What `externref` actually costs

Worth its own section because the result is uniform and the intuition is wrong.

Per-callback costs are derived from the `call` phase (marshalling excluded) divided by the
number of host callbacks the guest makes.

| Op | host callbacks the guest makes | ns per callback | vs best copying strategy |
|---|---:|---:|---:|
| `map_host` | 4,000 lookups | 40.5 | **3.6x slower** (225.2 vs 63.5 µs) — the closest it gets |
| `list` | 100,000 gets | 20.2 | 5.3x slower (2,108 vs 398 µs) |
| `str` | 47,947 code points + 2,000 lengths | 27.0 | 7.6x slower (1,498 vs 197 µs) |
| `set_host` | 65,536 membership tests | 47.9 | 77.6x slower (3,173 vs 41 µs) |

The module has **no linear memory at all** (`guests/wat/externref.wat`, 810 B, 549 B after
`-Oz`). Zero bytes are copied, ever. And it still loses badly whenever the guest iterates,
because you have traded one linear copy for a linear number of *crossings* — and an
`externref` crossing is not a cheap one. At 20–48 ns it is roughly 4–10x the ~5 ns scalar host
import [016](../016_ffi_assemblyscript/) measured (on wasmtime 36, so treat that as an
order-of-magnitude comparison, not a controlled one). The difference is that every callback
must resolve the GC handle (`Rooted::data`) and downcast the host object before it can do any
work.

The rule that falls out: **`externref` costs you in proportion to how much of the collection
the guest touches, and it never bought back the copy in any cell measured here.** A map lookup
reaches one entry out of a thousand and lands within 4% of hand-rolled binary search; a sum
touches every element and loses by 5.3x; a 65,536-probe membership scan loses by 78x. Nothing
about "avoiding marshalling" predicts the outcome — the ratio of elements-touched to
elements-in-collection does. Choose `externref` when copying is impossible or the collection
is a live host resource, not because it sounds cheaper.

---

## Binary size and glue code

### Guest binary size

| Artifact | raw B | after `wasm-opt -Oz` | what's in it |
|---|---:|---:|---|
| `wat_externref.wasm` | **810** | **549** | All four collections, no memory, no allocator |
| `wat_collections.wasm` | **1,721** | **1,175** | All four collections, bump allocator, UTF-8 decoder, binary search |
| `assemblyscript.wasm` | 9,823 | 9,761 | + AS runtime, GC, `Map`, `Set` |
| `rust_manual_nohash.wasm` | 22,315 | 16,532 | + Rust allocator, `str`, `Vec` |
| `rust_bindgen.wasm` | 26,670 | 20,225 | + externref table, wbindgen shims (**plus 10,453 B of JS**) |
| `component_core.wasm` | 27,690 | 20,312 | + `cabi_realloc`, canonical ABI shims |
| `component.wasm` | 28,496 | n/a † | component wrapper: +806 B of type/canon sections |
| `rust_manual.wasm` | 35,992 | 27,602 | + `HashMap` **and** `HashSet` |

† `wasm-opt` 131 does not process component binaries; the core module inside does optimise.

Two deltas worth having:

- **`std`'s hash collections cost a Rust guest 13,677 B raw / 11,070 B after `-Oz`** — the
  same crate with `--no-default-features` drops from 35,992 to 22,315. That is a real reason
  to prefer sorted pairs when you query a map once, on top of the ABI argument.
- **Wrapping a core module as a component costs 806 B** (27,690 → 28,496), all of it type and
  canonical-ABI metadata. The interface description is nearly free; the per-call cost is not.

The 1,721-byte hand-written WAT module implements all four collections including a UTF-8
decoder and two binary searches. Every other row is paying for a language runtime, not for
the ABI.

### Lines of glue — the cost nobody reports

`make glue`. Counted mechanically (`scripts/glue_loc.py`): every function that exists *only*
to move a collection across the boundary — allocation entry points, wire-format encoders and
decoders, per-element host callbacks. The four algorithm bodies are identical in all six legs
and are **not** counted. Blanks and comment-only lines excluded; `--verbose` prints the exact
lines counted.

| Leg | glue LoC | hand-written? | where |
|---|---:|---|---|
| **Component Model (WIT)** | **13** | declarative | `collections.wit` |
| AssemblyScript | 65 | yes | guest 24, host 41 |
| Rust manual | 61 | yes | guest 27, host 34 |
| WAT | 69 | yes | guest 35, host 34 |
| `externref` | 83 | yes | host import implementations only |
| **wasm-bindgen** | **234** | generated | `collections_bindgen.js` (10,453 B you ship) |

This is a real cost — it is code you write, review, test, and get wrong — and it is the
dimension on which the Component Model wins outright. 13 lines of WIT replace 61–83 lines of
hand-rolled convention, and unlike the wasm-bindgen row you don't ship them at runtime.

It is also the dimension where the honest failure mode lives. Writing this experiment, the
Node leg initially read `readFileSync(...).buffer.slice(0)` and silently loaded adjacent
pooled-buffer memory as workload data. It ran, it produced plausible timings, and the parity
gate caught it in one second. That bug is the entire subject of this experiment in miniature:
nothing in WebAssembly knows what your bytes mean.

---

## Verified by running vs. read in docs

**Measured, high confidence** — every table above; parity across 34 cells; the 30x component
call overhead and its falsification test with a `list<u32>` argument; the 1.393x UTF-16 byte
ratio; the 13,677 B `HashMap`/`HashSet` delta; the 6.5–16.5x bitset advantage reproduced in all six
legs; the forward/reverse ordering check.

**Verified by disassembly, not by documentation** — the `canon lift` options for every export
(`realloc`, `string-encoding=utf8`, `post-return` on the one aggregate-returning function);
that rustc lowers `-> String` to a scratch return pointer and wasm-bindgen adds a multi-value
shim on top; that `passArrayJsValueToWasm0` routes `Vec<String>` through the externref table.
Reproduce all of it with `make disasm`.

**Verified by running a probe** — AssemblyScript's `rtSize` at `ptr - 4` (`make probe`).

**Read in specs, not independently verified** — that the canonical ABI represents strings and
lists as "a pointer and length" and calls `realloc` "when lowering a value that requires
dynamic allocation"
([Canonical ABI explainer](https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md),
accessed 2026-08-02); AssemblyScript's full 20-byte managed header with `rtId` at −8
([assemblyscript.org/runtime.html](https://www.assemblyscript.org/runtime.html), accessed
2026-08-02) — the probe checks `rtSize` only.

**Inferred, lower confidence** — *why* a component call costs 330 ns (we showed it is fixed
per call and not the string/realloc path, but did not attribute it inside wasmtime); that the
bitset crossover density is ~3% (arithmetic from the representation sizes, not swept
empirically); that the AS hash-vs-sorted inversion is caused by transcoding specifically
(consistent with every other AS↔UTF-8 measurement here, but not isolated with a UTF-16-native
host).

## What isn't here

- **No browser leg.** Server-side only, by scope. The wasm-bindgen leg runs under Node.
- **Not every strategy has every cell, and the gaps are findings.** `map_handle` exists only
  in the Rust leg; `map_hash` and `set_hash` only in Rust and AssemblyScript. Nobody
  hand-writes a hash table in WAT, and neither a WIT export nor a stateless canonical-ABI
  function has anywhere to keep one between calls. Guest-side state needs a handle
  convention, and only the linear-memory strategies have one.
- **No AoS/struct-list leg** — [008](../008_js_vs_wasm_crossover/) measured that directly and
  this experiment cites it rather than re-deriving it.
- **The component leg's `marshal` is derived, not measured.** The canonical ABI copies *inside*
  the call, so there is no moment at which the host has written the data and not yet called.
  It is computed as the time of a `noop-*` export with an identical signature. Same for the
  wasm-bindgen leg. The linear-memory legs measure marshal directly, as its own loop.
- **`dealloc` is excluded from the timed marshal phase.** Allocations grow across rounds
  (bounded, a few MB). Free cost is part of the ownership story, discussed above, but not in
  the timings.
- **One host, one machine, one architecture.** Everything is wasmtime 47.0.3 on arm64 macOS
  except the Node leg. Component call overhead in particular is a host-implementation
  property and should be re-measured before being quoted elsewhere.

## Layout

```
guests/wat/collections.wat      leg 1 — bump allocator, UTF-8 decoder, svec, binary searches, bitset
guests/wat/externref.wat        leg 6 — no memory at all; 6 host imports
guests/rust_manual/             leg 2 — alloc/dealloc + ptr+len; `hashed` feature for the size delta
guests/rust_bindgen/            leg 3 — same bodies, ordinary Rust signatures
guests/assemblyscript/          leg 4 — UTF-16 strings, AS Map/Set, raw-memory svec reader
guests/component/               leg 5 — wit/collections.wit + wit-bindgen; no glue in the source
host/src/main.rs                CLI, one process per cell, workload dump
host/src/data.rs                deterministic workload + native reference checksums
host/src/core_leg.rs            driver for legs 1, 2, 4 (identical export signatures)
host/src/component_leg.rs       driver for leg 5 (wasmtime component typed API)
host/src/externref_leg.rs       driver for leg 6 (host import implementations)
js/bench_bindgen.mjs            leg 3 runner (Node)
js/as_layout_probe.mjs          AS object-header verification
scripts/report.py               results/*.jsonl -> the tables above + ordering + parity check
scripts/glue_loc.py             mechanical glue-line counter
build.sh / run.sh / Makefile
```

## Reproduce

```
make build      # all six guests + host, prints sizes raw and -Oz
make test       # validate every .wasm, then assert cross-leg parity
make bench      # full matrix, forward and reverse leg order -> results/
make report     # the tables above, plus the ordering and parity checks
make sizes      # binary sizes
make glue       # lines of glue per leg
make disasm     # canonical ABI lifts, wasm-bindgen's multi-value shim
make probe      # AssemblyScript string layout, verified by running it
```
