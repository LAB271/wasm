# Archetype: WASM as the OCI Workload (Shim Replaces runc)

> Exemplified by [experiment 018](../../experiments/018_wasm_platforms/):
> architecture 3 (`containerd-shim-wasmtime-v1` driven by raw `ctr`), leg 3b
> (podman + `crun`), and the k3d/SpinKube `RuntimeClass` path.

Status: Accepted

## System Context

Every other archetype in this repo asks "what runs the WASM?" This one asks
"what does the *orchestrator* schedule?" — and the answer is the module itself.

containerd delegates execution to a **shim**. Normally that shim is `runc`,
which creates namespaces and cgroups and execs a Linux process. Swap in a shim
that embeds a WASM runtime and the workload has **no Linux userspace at all**:

```
containerd ──► runc shim         ──► namespaces + cgroups + Linux process
           └─► wasmtime shim     ──► wasmtime.run(module.wasm)     ← nothing else
```

The image is `FROM scratch` plus one file. Measured in 018: **43.9 kB total**,
being a 40,445-byte `wasm32-wasip1` module and nothing besides — no distro, no
libc, no shell.

## Containers

| Container | Path | Role |
|-----------|------|------|
| Orchestrator | k8s / `ctr` / `podman` | Schedules the workload; unaware it is not a Linux container |
| Shim | `containerd-shim-wasmtime-v1`, or `crun` built `+WASM:wasmedge` | Replaces `runc`. Embeds the WASM runtime |
| Image | `FROM scratch` + `.wasm`, `ENTRYPOINT ["/x.wasm"]` | An OCI artifact whose only layer is the module |
| Guest | `wasm32-wasip1` module | Executes directly. No process, no userspace |

## How it differs from the existing archetypes

**Not [0004](0004-archetype-prebuilt-server-http-blackbox.md).** There you
*consume* an off-the-shelf server (`spin up`, `wasmtime serve`) as an opaque
binary you did not write. Here there is no server at all — the orchestrator
executes your module, and the runtime is a shim beneath containerd rather than a
process you launched.

**Not [0005](0005-archetype-embedded-runtime-library.md).** There *your* process
embeds wasmtime as a library and you control the host. Here the embedder is
infrastructure you did not write and do not link against.

The distinguishing property: **the WASM module is the scheduling unit.** It gets
an OCI reference, an image registry, a `RuntimeClass`, pod scheduling, and
everything else the container ecosystem provides — while being none of the things
a container is.

## The number that justifies this archetype existing

018 measured the same trivial workload three ways:

| | Median cold start | Δ vs container floor |
|---|---|---|
| podman + normal Linux process (`alpine echo`) | 169 ms | — (podman's own floor) |
| **podman + crun-wasm — WASM *is* the workload** | **217 ms** | **+48 ms** |
| Spin runtime *inside* a container ([003](../../experiments/003_wasm_compile/) leg 1b) | 1,238 ms | +1,061 ms |

**+48 ms against +1,061 ms — 22x.** Putting a WASM *runtime* inside a container
pays the container tax *and* the runtime's startup; making WASM *the workload*
pays only the orchestration floor.

*Caveat, stated because the comparison invites misreading:* the 1,238 ms figure
is time-to-first-HTTP-200 for a Spin server, while 217 ms is run-and-exit. The
strictly apples-to-apples pair is **169 ms vs 217 ms** — both trivial
run-and-exit — showing the wasm handler adds ~48 ms to a container that would
otherwise start a Linux process. The architectural conclusion survives either
reading.

## Constraints this archetype imposes

- **A shim must be installed on every node.** Verified on arm64:
  `containerd-shim-wasmtime-v1` has an `aarch64-linux-musl` build. Not assumed —
  Apple Silicon is where amd64-only tooling usually surfaces.
- **Dispatch is per-platform and does *not* port.** In k8s, `RuntimeClass` genuinely
  routes to the shim. In podman it does **not**: dispatch happens on the
  `module.wasm.image/variant` annotation, and `runtimeClassName` is accepted and
  silently ignored — 018 verified this three ways, including with a deliberately
  bogus runtime class that still ran. **The architecture ports; the manifest does
  not.**
- **No `--runtime` flag and no `containers.conf` registration is needed** for
  podman, because its default `crun` is already built `+WASM:wasmedge`. The
  widely-repeated recipe to register `crun-wasm` under `[engine.runtimes]` is
  wrong, and 018 documents the dead end.
- **`--platform=wasi/wasm32` is Docker-Desktop-specific**, not a generic `dockerd`
  capability. It fails on other daemons.
- The guest gets **WASI, not a Linux environment**. Anything expecting `/proc`, a
  shell, or `fork` does not apply here.

## When this is the right shape

Choose it when you want **container-ecosystem orchestration without container
cost**: image registries, `RuntimeClass`, pod scheduling, admission control and
observability, on workloads that start in tens of milliseconds and ship as
tens of kilobytes.

Choose [0004](0004-archetype-prebuilt-server-http-blackbox.md) instead if a
plain `spin up` on a host is sufficient — at 177 ms native it beats this path,
and needs no shim on any node.

Do **not** choose the middle ground of a WASM runtime inside an ordinary
container. 018 and 003 together show it is the worst of both: 1,238 ms, which is
slower than the plain Flask-in-Docker baseline (500 ms+) it was meant to beat.
It only makes sense when you need OCI orchestration *and* cannot install a shim.

## Experiment 018 findings

- Verified via raw `ctr --runtime=io.containerd.wasmtime.v1` against
  `ghcr.io/containerd/runwasi/wasi-demo-app` — genuine WASM as PID 1 on arm64.
- Verified via k3d + SpinKube `spin-operator` with the `wasmtime-spin-v2`
  `RuntimeClass`, serving real HTTP; image 524.4 KiB.
- Verified via podman + `crun` at 217 ms median, with `podman run` and
  `podman play kube`.
- Krustlet (a kubelet replacement that ran WASM instead of containers) is the
  archived predecessor. The shim approach superseded it because it reuses all
  existing scheduling, networking and observability rather than forking the
  control plane.

## Open questions

- Cold start was measured for run-and-exit workloads. A long-lived HTTP server
  under the shim has not been benchmarked against `spin up` native.
- Memory per workload under the shim was not isolated from containerd's own
  overhead.
- Whether the annotation-vs-RuntimeClass split is a podman implementation detail
  or a durable divergence is unresolved; it is worth re-testing as both mature.
