# WASM Research — Sources and Findings

> Compiled 2026-07-31. Primary sources only where possible; the "WASM in 2026" blog
> genre is largely SEO filler and is deliberately excluded.

Scope: authoritative reference material for WASM on both sides of the split this
repo cares about — **client side** (browser) and **server side** (serverless /
containers) — plus findings from checking MVL's `--backend=wasm` stdio support
against a real WASI host.

---

## 1. Normative / specification

| Source | Why it matters |
|---|---|
| [WebAssembly 3.0 Core Specification (live)](https://webassembly.github.io/spec/core/) | The live standard. Version seen 2026-07-28. Adds 64-bit memories/tables, GC (`struct`/`array` heap types), tail calls, exception handling, relaxed SIMD. |
| [Wasm 3.0 Completed](https://webassembly.org/news/2025-09-17-wasm-3.0/) | Announcement, 2025-09-17. Best readable summary of the 2.0 → 3.0 delta and the rationale. |
| [Change History appendix](https://webassembly.github.io/spec/core/appendix/changes.html) | Feature-by-feature delta. The reference for deciding what a code generator may assume. |
| [webassembly.org/specs](https://webassembly.org/specs/) | Index of the JS API, Web API, and proposal-stage specs. |
| [W3C wasm-core-2](https://www.w3.org/TR/wasm-core-2/) | The W3C TR track copy — lags the live spec; cite for formal references. |
| [WebAssembly/WASI](https://github.com/WebAssembly/WASI) | Normative WASI worlds. `wasi-cli` and `wasi-http` are the WITs server hosts actually import. |
| [The Component Model book](https://component-model.bytecodealliance.org/) | Canonical explainer for WIT, worlds, and the canonical ABI. The one to read properly. |
| [The Road to Component Model 1.0](https://bytecodealliance.org/articles/the-road-to-component-model-1-0) | Bytecode Alliance's own roadmap. |

### Version landscape

- **Wasm 3.0** — completed September 2025, shipping in major browsers; standalone
  engine support (Wasmtime et al.) reported as on track to completion.
- **WASI 0.2 (Preview 2)** — the stable, widely-implemented target today.
- **WASI 0.3 (Preview 3)** — headline feature is native async I/O in the Component
  Model (`future` / `stream` types) replacing 0.2's `poll`-based streams. Secondary
  reporting puts the 0.3.0 release at February 2026 and WASI 1.0 standardization
  during 2026; treat both dates as unverified against a primary source.
- **WASI Preview 1 (`wasi_snapshot_preview1`)** — legacy, but still the pragmatic
  target for a new backend: a handful of imports gets you a working CLI program,
  and every major runtime still executes p1 modules. This is what MVL targets
  (`wasm32-wasip1`).

---

## 2. Client side (browser)

| Source | Why it matters |
|---|---|
| [MDN WebAssembly reference](https://developer.mozilla.org/en-US/docs/WebAssembly) | The JS API: `WebAssembly.Module` / `Instance` / `Memory` / `Table`, instantiation semantics. The practical contract a generated module must satisfy. |
| [wasm-bindgen guide](https://rustwasm.github.io/wasm-bindgen/) | Best-documented worked example of a string / array / opaque-handle ABI across the JS boundary. The "Reference → Types" section is the useful part even if you emit no Rust. |
| [jco](https://github.com/bytecodealliance/jco) | Bytecode Alliance component → JS transpiler. The route to running components in a browser without hand-written glue. |
| [wasm-tools](https://github.com/bytecodealliance/wasm-tools) | `wasm-tools parse` / `validate` / `objdump` / `wit-component`, plus `wasm-smith` for fuzzing. Reference implementation; the thing to gate CI on. |

**Browsers have no WASI.** No blocking syscalls, no real stdin, no
`wasi_snapshot_preview1` without a JS shim. Console-driven programs do not map to a
browser tab. Shims exist ([`@bjorn3/browser_wasi_shim`](https://github.com/bjorn3/browser_wasi_shim),
`@wasmer/wasi`) but they emulate a filesystem and stdio over JS objects — useful for
a playground, not equivalent to a host. See experiment
[004](../experiments/004_static_wasi_hello/) and
[010](../experiments/010_mastermind_web/) for what this costs in practice.

---

## 3. Server side (serverless / containers)

| Source | Role |
|---|---|
| [Wasmtime docs](https://docs.wasmtime.dev/) | Reference WASI / Component Model runtime and the de-facto conformance target. Used by Fastly and Shopify. |
| [Spin](https://spinframework.dev/v2/quickstart) | Fermyon's serverless framework on Wasmtime. CNCF Sandbox; ships as a containerd shim so Wasm workloads schedule natively in Kubernetes. Best on-ramp for the "serverless component" shape. |
| [wasmCloud](https://wasmcloud.com/) | CNCF Incubating. Actor / capability-provider model, distributed. Orchestration-first rather than function-first — a different bet than Spin. |
| [WasmEdge](https://wasmedge.org/) | C++, CNCF. Strong on AI-inference plugins and edge; also a containerd shim. |
| [Cloudflare Workers — WebAssembly](https://developers.cloudflare.com/workers/runtime-apis/webassembly/) | Note their WASI support is explicitly experimental with only some syscalls implemented. You get core Wasm plus Cloudflare bindings, not a full WASI world. |
| [wasm-runtime-comparison](https://github.com/wasmruntime-io/wasm-runtime-comparison) | Wasmtime / Wasmer / WasmEdge / wazero / WAMR feature matrix and benchmarks. Feature matrix is useful; treat benchmarks as directional only. |
| [awesome-webassembly-runtimes](https://github.com/jcbhmr/awesome-webassembly-runtimes) | Curated runtime list for anything not covered above. |

Runtime shorthand: **Wasmtime** (Rust, standards-first, server security),
**Wasmer** (Rust, pluggable engines, run-anything), **WasmEdge** (C++, AI/edge,
Kubernetes), **wazero** (Go, zero-CGO embedding), **WAMR** (C, IoT/embedded,
Intel SGX, minimum footprint).

---

## 4. Running WASM straight in the terminal

The question "is there a wasm CLI with full stdin/stdout/stderr?" resolves to the
WASI **`command`** world, and `wasmtime run` is its driver. Stdio is inherited from
the terminal by default — no flags, no shim.

```bash
wasmtime run module.wasm            # _start, stdio inherited
wasmtime run --preload runtime=rt.wasm module.wasm
```

Verified locally: `wasmtime 43.0.1 (cd4b6ed9b 2026-04-09)`,
`wasm-tools 1.245.1`.

Minimum for a Preview 1 CLI program: export `_start`, import `fd_write` (stdout /
stderr), `fd_read` (stdin), `proc_exit`. Peers with the same capability:
`wasmer run`, `wasmedge`, `wazero run`, `iwasm` (WAMR). Node has `node:wasi`
behind `--experimental-wasi-unstable-preview1`.

Experiment [011](../experiments/011_mastermind_cli_wasi/) already establishes the
baseline: pure Rust → `wasm32-wasip1` → real WASI `fd_read` stdin, fully
interactive under `wasmtime run`. **Genuine interactive terminal I/O under WASM/WASI
is not in question.** Anything that fails is host- or toolchain-specific.

---

## 5. Findings — MVL `--backend=wasm` stdio

Checked against `mvl-lang/mvl` at `55cd9e3d`. All claims below were reproduced
locally, not inferred.

### What works

`stdout` / `stderr` are real. `src/mvl/backends/wasm_text.rs:7542` imports
`wasi_snapshot_preview1.fd_write` (and `clock_time_get` at `:7549`), and
`println` / `eprintln` / `write(fd, msg)` on fd 1/2 lower correctly.

### What does not

**No `fd_read` import exists anywhere in the emitter.** The only occurrence of the
name is a comment at `wasm_text.rs:484` explaining that file reads go through the
runtime crate's `std::fs` instead. `runtime/wasm/src/lib.rs` has no `read_line`.

`std/io.mvl` nonetheless declares the full surface — `stdin() -> Fd` at `:116`,
`read_line(fd: Fd) -> Result[Tainted[String], IoError] ! Console` at `:182` — and
programs using it **type-check clean**.

### The failure is a dangling call, not a stub

This is the part worth recording, because it is not what the tracking issue says.

Repro:

```mvl
use std.io.{read_line, stdin}

fn main() -> Unit ! Console {
    match read_line(stdin()) {
        Ok(line) => println(relabel trust(line, "STDIN-001")),
        Err(_) => eprintln("read failed"),
    }
}
```

`mvl check` → `OK (9/11 requirements proven)`. `mvl build --backend=wasm` → exit 0,
two `[REQ1] undefined function` warnings, WAT written. The emitted body contains:

```wat
call $stdin
call $read_line
```

Neither `$stdin` nor `$read_line` is defined or imported anywhere in the module.
Assembly therefore fails outright:

```
error: unknown func: failed to find name `$stdin`
     --> echo.wat:227:10
```

The `unreachable` further down that function is the match-exhaustiveness
fallthrough, **not** a `read_line` stub. The defect is a reference to a
non-existent function, which invalidates the entire module — every unrelated
function in the file goes down with it.

### It is not stdin-specific

The emitter does have `stdout` / `stderr` / `stdin` arms — local collection at
`wasm_text.rs:1972`, emission at `:2604` — but the emitting arm is guarded by
`ctx.struct_layouts.get("Fd")`. When that lookup misses, control falls through to
generic call emission and produces the dangling call. `struct_layouts` is built by
`collect_structs(&tir.types)` at `:605`, so it depends on how `Fd` reaches the TIR.

Isolated by varying only the binding shape:

| Program | Result |
|---|---|
| `write(stdout(), "hi\n")` — inline argument | assembles OK |
| `let f: Fd = stdout(); write(f, "hi\n")` | `unknown func: $stdout` |
| `let f: Fd = stdin()` | `unknown func: $stdin` |

So **`stdout()` breaks too**, on exactly the same path. The bug is "an `Fd`-typed
binding emits a dangling call", not "stdin is unimplemented". The `write(stdout(), …)`
shape that #2056's tests cover happens to be the one shape that works.

### The gate cannot catch this class

`make wasm-stub-report` scans emitted WAT for `unreachable` stubs. A dangling call
contains no `unreachable`, so the class is structurally invisible to it — and
`mvl build --backend=wasm` exits 0. Nothing in CI today fails on a module that
cannot assemble unless it is in `WASM_CORPUS`, which only started validating in
#2081.

### Upstream issues

| Issue | State | Relation to the above |
|---|---|---|
| [mvl#2088](https://github.com/mvl-lang/mvl/issues/2088) | open | `feat: WASI fd_read + read_line for CLI/server WASM targets`. The ask is right. Its premise — "`stdin()` is a stub `Fd` value that never actually reads" — is wrong: it emits an invalid module, and the problem is not stdin-specific. [Corrected in-thread](https://github.com/mvl-lang/mvl/issues/2088#issuecomment-5143472803); now scoped to the `read_line` feature gap only. |
| [mvl#2090](https://github.com/mvl-lang/mvl/issues/2090) | open | Filed from §5. The dangling-call bug: `Fd`-typed bindings emit `call $stdout` / `$stdin` against nothing. Blocks `stdout` too, independently of any WASI import. |
| [mvl#2091](https://github.com/mvl-lang/mvl/issues/2091) | open | Filed from §5. Gate on assembly, not stubs — `wasm-stub-report` is structurally blind to dangling calls. |
| [mvl#2084](https://github.com/mvl-lang/mvl/issues/2084) | open | Survey: 11 of 22 examples emit modules that cannot load. Listed mastermind's blocker as `$stdin` and asked for diagnosis, not a shim — [answered in-thread](https://github.com/mvl-lang/mvl/issues/2084#issuecomment-5143481805) and reclassified to #2090. Its category C (undeclared String locals) may share the same root cause. |
| [mvl#2089](https://github.com/mvl-lang/mvl/issues/2089) | open | Spike: browser-hosting model, scoped around actors; explicit non-goal is stdin/console programs. Consistent with §2. |
| [mvl#2076](https://github.com/mvl-lang/mvl/issues/2076) | closed | `read_file`/`FileRead` had no import or runtime shim — same shape, already fixed via the runtime crate. The precedent for how to fix `read_line`. |
| [mvl#2066](https://github.com/mvl-lang/mvl/issues/2066) | closed | `Result::Err` limited to `String` payloads. |
| mvl#2014 / #2081 | merged | funcref table + `call_indirect` for List HOFs; corpus validation and the stub report. |

### Recommended fix direction

Two options for `read_line`:

1. **`fd_read` directly** — import `wasi_snapshot_preview1.fd_read`, add a
   line-buffered read loop to the WAT prelude beside the existing `fd_write`
   helpers. Self-contained; mirrors how #2056 did the write side. Requires
   hand-rolled newline and UTF-8 scanning in WAT.
2. **Push it into `runtime/wasm/`** — implement `read_line` in the Rust crate over
   `std::io::stdin()`, which `wasm32-wasip1` supports natively, and have the emitter
   call it through the preload.

(2) is the better fit: it matches the precedent already set for `read_file` (#2076)
and avoids buffer management in generated WAT.

Independently of either, two things are worth fixing because they are cheap and
they are why this stayed invisible — both now filed:

- Make the `struct_layouts.get("Fd")` miss a hard error rather than a silent
  fallthrough to generic call emission — [#2090](https://github.com/mvl-lang/mvl/issues/2090).
- Gate on assembly, not just on stubs — `wasm-tools parse` every emitted module,
  including examples, and fail the build on a dangling reference —
  [#2091](https://github.com/mvl-lang/mvl/issues/2091).

---

## 6. Bearing on this repo's premise

Two things the sources settle for the container-replacement hypothesis:

- **Cold start is real but the comparison is often rigged.** Modules instantiate
  without an OS to boot or a container runtime to start. Experiment
  [009](../experiments/009_rust_native_host/) already checks a published "200µs"
  claim against its own methodology — the sources in §3 do not change that
  conclusion, and vendor benchmarks should be read the same way.
- **The Component Model is what makes server-side Wasm more than a sandbox.** WIT
  plus the canonical ABI is the difference between hand-written FFI and type-safe
  composition across languages. Anything targeting §3's platforms should assume
  components, and target WASI 0.3 rather than 0.2 for new work with async I/O.

---

## Source list

**Spec / normative**
- <https://webassembly.github.io/spec/core/>
- <https://webassembly.org/news/2025-09-17-wasm-3.0/>
- <https://webassembly.github.io/spec/core/appendix/changes.html>
- <https://webassembly.org/specs/>
- <https://www.w3.org/TR/wasm-core-2/>
- <https://github.com/WebAssembly/WASI>
- <https://component-model.bytecodealliance.org/>
- <https://bytecodealliance.org/articles/the-road-to-component-model-1-0>

**Client side**
- <https://developer.mozilla.org/en-US/docs/WebAssembly>
- <https://rustwasm.github.io/wasm-bindgen/>
- <https://github.com/bytecodealliance/jco>
- <https://github.com/bytecodealliance/wasm-tools>
- <https://github.com/bjorn3/browser_wasi_shim>

**Server side**
- <https://docs.wasmtime.dev/>
- <https://spinframework.dev/v2/quickstart>
- <https://wasmcloud.com/>
- <https://wasmedge.org/>
- <https://developers.cloudflare.com/workers/runtime-apis/webassembly/>
- <https://github.com/wasmruntime-io/wasm-runtime-comparison>
- <https://github.com/jcbhmr/awesome-webassembly-runtimes>
