# Archetype: Host-Import Bridge (Keep the Guest Tiny, Lend It Capabilities)

> Exemplified by [experiment 015](../../experiments/015_postgres_bridge/)
> (Postgres via host imports) and
> [experiment 016](../../experiments/016_ffi_assemblyscript/)
> (AssemblyScript calling a Rust host for SHA-256).

Status: Accepted

## System Context

The guest does not implement the capability. It **imports a few functions the
host implements**, and stays small and portable as a result:

```
guest.wasm  ──imports──►  host_query(sql_ptr, len) -> rows_ptr
   ~400 B                 host_sha256(ptr, len) -> digest_ptr
                                    │
                          host (native Rust, embeds wasmtime)
                                    │
                          real Postgres driver / SHA-NI instructions
```

This is not "a custom ABI instead of WASI" ([0003](0003-archetype-custom-hand-rolled-abi.md)) —
the guest can still be an ordinary WASI module. It is **WASI plus a handful of
bespoke imports**, added where the standard worlds have no answer or where the
host can do the job far better.

## Containers

| Container | Path | Role |
|-----------|------|------|
| Guest | `wasm32-wasip1` module, often `no_std` | Business logic only. Calls out for anything it should not own |
| Import surface | a few host functions, ptr+len ABI | The contract. Small enough to review by eye |
| Host | native process embedding wasmtime ([0005](0005-archetype-embedded-runtime-library.md)) | Implements the imports against real drivers and real hardware |

## Why it exists: the numbers

**A host import call is nearly free.** 016 measured **~5 ns** per crossing —
close to a native function call, and low enough that it is never the reason to
avoid this shape.

**It beats the obvious alternative by 4x.** 015 replaced an HTTP sidecar with
host imports for database access:

| Approach | Per-query latency | Guest size impact |
|----------|------------------:|-------------------|
| **Host imports** | **~460 µs** | ~400 B guest |
| HTTP sidecar | ~2 ms | small, but needs an HTTP client |
| Embedded SQLite in the guest | ~1 ms | **+1 MB**, and needs a WASI SDK to compile |

**It buys access to hardware the guest cannot reach.** 016: SHA-256 over 1 KB
costs **764 ns via a host import** against roughly **50 µs computed in pure
WASM** — because the host reaches SHA-NI/AES-NI instructions that WASM has no
way to express. Hardware crypto is **50–100x** faster, and there is no amount of
guest optimisation that closes it.

## The cost that is easy to miss

**Through the Component Model's canonical ABI, a call is ~30x more expensive.**
[008](../../experiments/008_js_vs_wasm_crossover/) measured a core-module call at
**10.8 ns** and a typed component call at **332.9 ns** — fixed per call, not
per byte, and not string-specific.

So this archetype is cheap on **core modules** and materially less cheap through
**components**. If the import is chatty, that 30x lands on every call. Batch at
the interface — hand across sixteen items rather than one — and it amortises;
008's granularity sweep put the crossover at K≈4–16 elements per call.

## How it differs from the existing archetypes

**Not [0003](0003-archetype-custom-hand-rolled-abi.md).** There the compiler emits
a *whole* bespoke namespace (~60 functions) and WASI is absent entirely. Here the
guest is a normal WASI module with a handful of extra imports bolted on. 0003 is
a replacement; this is an extension.

**Not [0005](0005-archetype-embedded-runtime-library.md), but requires it.** 0005
is about *who runs the module* — your own process, in-process, natively. This
archetype is about *what that host offers across the boundary*. You need 0005 to
do this, because only an embedder you control can add imports.

**Not [0008](0008-archetype-guest-owned-sockets.md).** There the guest owns a real
socket via `wasi:sockets` and speaks the protocol itself. Here the guest never
sees a socket; the host does the networking and hands back results.

## Constraints this archetype imposes

- **The import surface is an unversioned private contract.** There is no spec, no
  validator, no third party implementing it. It is exactly as correct as whoever
  wrote both halves — the same warning [0003](0003-archetype-custom-hand-rolled-abi.md)
  records, in smaller doses.
- **The guest is not portable to hosts that lack your imports.** It will fail to
  link, not fail gracefully. This is the trade for the 4x and the 50–100x.
- **Marshalling is yours to get right.** ptr+len, who allocates, who frees. See
  [020](../../experiments/020_collections_abi/) for what that costs by data shape:
  scalars and typed arrays are nearly free, strings cost encoding, arrays-of-objects
  cost an AoS→SoA transform.
- **Blocking host calls block the guest.** 015's host is synchronous; a slow query
  stalls the instance.

## When this is the right shape

Choose it when the guest needs something it **cannot** do (hardware crypto, a real
database driver) or **should not** do (+1 MB of embedded SQLite, credential
handling), and you already control the host.

Prefer [0008](0008-archetype-guest-owned-sockets.md) if the guest genuinely should
own the protocol. Prefer [0004](0004-archetype-prebuilt-server-http-blackbox.md)
if you would rather not write host code at all — and accept the ~2 ms sidecar hop
that 015 measured as the price of that.

## Findings

- ~5 ns per host-import crossing ([016](../../experiments/016_ffi_assemblyscript/)).
- 460 µs Postgres query via host imports vs ~2 ms via an HTTP sidecar, 4x
  ([015](../../experiments/015_postgres_bridge/)).
- SHA-256 1 KB: 764 ns host-side vs ~50 µs in-guest; hardware crypto 50–100x
  ([016](../../experiments/016_ffi_assemblyscript/)).
- Core-module call 10.8 ns vs typed component call 332.9 ns, ~30x, fixed per call
  ([008](../../experiments/008_js_vs_wasm_crossover/)).

## Open questions

- 015's host is synchronous. An async host offering the same imports (so a slow
  query yields rather than stalls) has not been built or measured.
- Connection pooling lives entirely host-side in 015; how it should be surfaced to
  a multi-tenant guest population is unexplored.
- Whether the ~30x component-call overhead narrows as wasmtime's component
  implementation matures was measured once, on one version, and should be
  re-checked rather than assumed durable.
