# Experiment 009 — Native Rust Host, In-Process, No HTTP

Prompted directly by [Erwin Hermanto's "WebAssembly on the Server"](https://medium.com/@erwindev/webassembly-on-the-server-why-im-betting-on-wasm-as-the-next-backend-primitive-e1d730480a7f):
a Go program embedding `wazero` (a pure-Go WASM runtime) as a library, loading a
user-provided plugin, and calling it directly — no container, no HTTP, no
subprocess. That's a genuinely different architecture from anything else in this
repo. Every WASM host built so far here is either a browser Worker
(experiments 004–008) or a pre-built server treated as a black box
(`wasmtime serve`, `spin up` in 001/003). Nobody had embedded a WASM runtime as a
library in a native process and called a function directly, in-process.

This experiment builds that missing architecture in Rust rather than Go — using
the `wasmtime` crate directly, the same engine `wasmtime serve` already wraps
elsewhere in this repo, just as a library instead of a CLI.

## The methodological gap in the article, addressed directly

The article's headline number — "200 microseconds, on average" — comes from a loop
that compiles the module **once**, outside the timed loop, then measures 1,000
iterations of instantiate+call+close inside an already-running, already-warm Go
process. That's a real number, but it isn't a cold start in the sense the
article's own opening story uses the word (SSH in, deploy, first request). This
experiment measures both, and keeps them separate rather than picking one.

## Results

### True cold start (external wall-clock, includes OS process launch)

| | Internal timer (engine init + compile + call) | External (`time`, includes OS process launch) |
|---|---|---|
| First invocation of a freshly-built binary | 3,886µs (3.9ms) | **190ms** |
| Second invocation (OS file cache now warm) | 587µs | **4ms** |

The ~186ms gap on the first run is not wasmtime — it's the OS loading a binary
whose pages aren't in the file cache yet. It's real, it's what a genuinely cold
deploy looks like, and no measurement taken from *inside* the process (as the
article's does, and as this experiment's own `--single-shot` internal timer does)
can see it, because the internal clock only starts after the OS has already
finished exec'ing the binary. Reproduced identically across two independent
clean-room builds.

### Warm-loop benchmark (the article's own methodology, reproduced faithfully)

```
first iteration (includes any first-call JIT lag): 64-172us (varies by run)
remaining 999 iterations: min=8-13us median=9-15us avg=10-15us max=18-101us
```

**~13x faster than the article's 200µs, and the honest reason isn't (only)
"Rust is faster."** Two real differences, not one:

1. **Different runtimes, different languages.** `wasmtime` is a mature,
   Cranelift-JIT-backed engine, called here with zero FFI/cgo tax since both the
   host and the runtime are Rust. `wazero` is a pure-Go *reimplementation* of a
   WASM engine — no cgo either, but a different, younger compiler pipeline. Some
   of the gap is genuinely "which engine, called from what."
2. **This benchmark's payload does zero data marshalling.** `transform(i64) -> i64`
   — one integer in, one integer out, no memory access at all. The article's
   `Transform` function does real work crossing the boundary: `malloc`, write
   input bytes into WASM linear memory, call, read output bytes back out. That
   marshalling cost is real and this experiment's payload doesn't pay it —
   experiments 007 and 008 already measure that cost (handle-based string
   marshalling) and it is not free. **This number isolates pure call overhead,
   not realistic call-with-data overhead** — a narrower, smaller thing than what
   the article measured, and it would be dishonest to present it as a direct
   "Rust beats Go by 13x" result without that caveat.

## Usage

```bash
./build.sh
./benchmark.sh
# or directly:
./host/target/release/wasm_host --single-shot
./host/target/release/wasm_host --loop 5000
```

## Structure

```
009_rust_native_host/
├── README.md
├── build.sh
├── benchmark.sh
├── guest/
│   ├── Cargo.toml           # wasm32-unknown-unknown, zero imports
│   └── src/lib.rs           # transform(i64) -> i64 — deliberately trivial
└── host/
    ├── Cargo.toml           # wasmtime crate, no wasmtime-cli, no HTTP server
    └── src/main.rs          # --single-shot (true cold start) / --loop N (warm)
    # */target/ is build.sh output, gitignored
```

## What this doesn't test (yet)

Realistic data marshalling (see caveat above), and running MVL's own compiled
output (e.g. `mastermind`'s `score_guess`, already proven to compile clean to
`wasm32-wasip1` — see experiment 010) through this same native host instead of a
throwaway Rust payload. That would need porting `mvl-runtime.js`'s ~60 functions
to Rust — a real, separate effort, not done here to keep this experiment's own
question (does in-process native hosting look like the article claims) answerable
on its own.
