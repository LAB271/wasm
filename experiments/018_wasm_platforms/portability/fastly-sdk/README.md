# Fastly Compute via Fastly's own SDK

This is **not** a portability leg. It is the necessary counterpart to one.

Leg 4 shows the portable wasi:http component cannot run on Viceroy — not at any
wasi version, because Viceroy implements no `wasi:http` at all. Its ABI is
`fastly:compute/*`, and its HTTP entry point is
`fastly:compute/http-incoming@0.1.0`.

So the obvious question is whether Fastly runs WebAssembly *at all*. It does,
very well — via its own SDK:

```
$ curl -i http://127.0.0.1:19006/
HTTP/1.1 200 OK
content-type: text/plain; charset=utf-8
content-length: 22

Hello from wasmCloud!
```

```
INFO request{id=0}: request completed using 1.2 MB of WebAssembly heap
INFO request{id=0}: request completed in 561µs
INFO request{id=0}: response status: 200
```

No experimental banner, no linker error. This is the supported path.

## Three files, no scaffolder

`fastly compute init` **panics** — and not because of an unreleased build. First
seen on `vHEAD-89619cb`, then reproduced identically on **stable v15.4.0**:

```
panic: runtime error: index out of range [0] with length 0
  compute.(*InitCommand).PromptForStarterKit ... init.go:808
```

The starter-kit list comes back empty and the code indexes `[0]` unconditionally.
Reproduced interactively, non-interactively, and with `--accept-defaults`, on a
released version. A genuine upstream bug, worth filing.

**The fault is isolated to the starter-kit listing.** Bypass that one prompt and
the same command works:

```bash
fastly compute init --from https://github.com/fastly/compute-starter-kit-rust-default
# SUCCESS: scaffolds Cargo.toml, fastly.toml, rust-toolchain.toml, src/
```

Upgrading the CLI (HEAD -> 15.4.0) left Viceroy at 0.20.1, so leg 4's finding is
unchanged by it.

This directory takes the third option: skip the scaffolder entirely, since a
Compute project is only `Cargo.toml` (depend on `fastly`), `src/main.rs`, and
`fastly.toml`. Then:

```bash
fastly compute build      # cargo build --target wasm32-wasip1 + package
fastly compute serve      # Viceroy
```

## What this actually establishes

|  | Portable wasi:http component | This, via the `fastly` crate |
|--|------------------------------|------------------------------|
| Interface | `wasi:http/incoming-handler` | `fastly:compute/http-incoming` |
| Runs on Viceroy | **No**, and cannot | **Yes** |
| Runs on wasmtime/Spin/wasmCloud | **Yes**, unmodified | No |
| Same bytes as the other legs | Yes | **No** |

Both rows are true at once, and together they are the finding: **Fastly's
WebAssembly story is SDK-shaped, not wasi-http-shaped.** That is an
architectural choice, not a deficiency — but it does mean a Fastly guest and a
wasi-http guest are not interchangeable in either direction. Compare Cloudflare,
where the format gap was bridgeable (leg 6) because the host was ours to write.
