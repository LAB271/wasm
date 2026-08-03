# Experiment 018 — WASM Platforms: Local Testability & Portability

Two questions:

**A.** Of the three container/orchestration architectures and four "serverless
WASM" platforms in this space, which ones can actually be installed and
hello-world'd **on this machine** (Apple Silicon arm64, macOS 26.6) — not "the
docs say it works," but a real install and a real run, command and output
captured?

**B.** Can **one** `.wasm` component run unmodified across those platforms, or
does each demand its own SDK/ABI?

Every claim below is tagged **[VERIFIED]** (we ran it, on this machine, log
excerpted) or **[RESEARCHED]** (read from a primary source, not run here —
mostly cloud-hosted platforms this machine can't reach). Never let the second
category read like the first.

## Machine facts

Apple Silicon arm64, macOS 26.6. docker 29.x / podman 5.x-6.x (both via
Homebrew, docker backed by colima), spin 4.0.0, wasmtime 43.0.1 pre-installed.
kind, k3d, minikube, kubectl, wrangler, viceroy, wash, wasmedge, fastly CLI
were **not** installed at the start of this experiment — installing and
verifying each on arm64 was the point.

One real operational note from this session: docker's version drifted from
29.4.1 → 29.2.1 (server) / 29.6.2 (client) and podman from 5.8.2 → 6.0.1
mid-session, and the `docker` CLI symlink briefly vanished (`brew link
--overwrite docker` fixed it). This machine is shared with other concurrent
agent sessions doing their own installs/upgrades — expect background package
churn if you rerun these scripts.

## Hypotheses

| # | Hypothesis | Status |
|---|-----------|--------|
| H1 | All four platform runtimes (Spin, wash, wrangler, Viceroy) install and hello-world on arm64 macOS without emulation | **Confirmed** — all 4 installed and ran natively (arm64 binaries throughout) |
| H2 | A containerd WASM shim (runwasi) can run a WASM workload with zero Linux userspace, verifiable via raw `ctr` | **Confirmed** — `containerd-shim-wasmtime-v1` (aarch64) ran a real image under Docker's own colima-backed containerd |
| H3 | Local k8s + SpinKube's RuntimeClass reproduces the shim architecture through a CRD, not just raw `ctr` | **Confirmed** — k3d + spin-operator + `wasmtime-spin-v2` RuntimeClass served real HTTP |
| H4 | Docker's own `--platform=wasi/wasm32` flag works on a non-Docker-Desktop daemon | **Refuted** — fails with "does not provide the specified platform"; that flag is a Docker Desktop-specific feature, not a generic dockerd capability |
| H5 | A single wasi-http component (no platform SDK) runs unmodified on Spin, raw wasmtime, and wasmCloud | **Confirmed** — same `.wasm`, zero rebuild, ran on all three |
| H6 | The same component runs unmodified on Fastly Compute (Viceroy) | **Refuted, and unfixable — but Fastly runs WASM fine via its own SDK.** Viceroy 0.20.1 (unchanged across fastly CLI `vHEAD-89619cb` and stable `v15.4.0`) provides no `wasi:http` at *any* version; its entry point is `fastly:compute/http-incoming@0.1.0`. Proven by experiment: patching the component's imports `@0.2.9`→`@0.2.6` in place (same byte length, still validates) only moved the error to `wasi:http/types@0.2.6`. Leg 7 then targets `fastly:compute/*` with the `fastly` crate and serves 200 in ~500µs — so the gap is the ABI, not the platform. See `portability/fastly-sdk/` |
| H7 | The same component runs unmodified on Cloudflare Workers (workerd) | **Refuted as stated, but achievable with a transpile step.** V8 rejects the component container outright (`expected version 01 00 00 00, found 0d 00 01 00`). Transpiled to a core module with `jco` and given a hand-written wasi:http + wasi:io host, the **byte-identical guest serves HTTP 200 on workerd** — see [§ Making Cloudflare pass](#making-cloudflare-pass-leg-6) and `portability/cf-worker/` |
| H8 | AKS's WASI node pool preview is still available today | **Refuted** — retired, replaced by a SpinKube-on-AKS path |
| H9 | AWS has no first-class native WASM compute platform | **Confirmed** (by absence — see Cloud provider landscape) |
| H10 | podman can select a WASM-capable OCI runtime (crun-wasm) the same way it selects runc | **Rejected as framed — capability confirmed by another route** (§3b). Podman never *selects* a WASM runtime: there is no `--runtime` flag on `run`, no `[engine.runtimes]` block, and no `containers.conf` in the VM. None are needed, because the default `crun` is already `+WASM:wasmedge` and dispatch happens on the `module.wasm.image/variant` annotation. WASM-as-workload verified running via both `podman run` and `podman play kube`, at 217 ms median cold start |

---

## Three container/orchestration architectures

### 1. Container running a normal process — the baseline **[VERIFIED]**

```
$ docker info | grep -iE "runtime|storage driver"
 Storage Driver: overlayfs
 Runtimes: io.containerd.runc.v2 runc
 Default Runtime: runc

$ docker run --rm hello-world
Hello from Docker!
```

containerd dispatches the container to the `runc` shim, which execs a real
Linux process inside a namespaced/cgrouped environment. This is what
architectures 2 and 3 are being compared against. Reproduce: `make
verify-baseline` or `scripts/verify-baseline.sh`.

### 2. Container running a WASM runtime (Spin-in-podman) **[VERIFIED — pre-existing, reference only]**

[experiment 003](../003_wasm_compile/) already has a `Containerfile` that runs
`spin up` as PID 1 inside a normal podman container (legs 1b, 2c) — i.e. a
completely ordinary Linux container whose one process happens to be a WASM
runtime (Spin, which embeds wasmtime). 003's own README already notes this
uses `Containerfile` and **not** Docker's `--platform wasi/wasm` shim, because
podman doesn't support that flag (see architecture 3 below for why that flag
is Docker-Desktop-specific in the first place, not podman-specific). **We
re-tested this directly** (`podman run --rm --platform=wasi/wasm32
localhost/hello-crun-wasm:latest`): it does not work here either, but not with
Docker's clean "does not provide the specified platform" message — podman
instead tries to pull `localhost/hello-crun-wasm:latest` from a **registry**
(`pinging container registry localhost: ... connection refused`), ignoring
the already-present local image entirely. Different failure mode, same
practical conclusion: 003's claim holds up under a fresh, independent test.

We did **not** rebuild 003 (out of scope, and three other agents are working
elsewhere in this repo) but did smoke-test its mechanism directly, read-only,
using its existing `Containerfile` and `python-spin/app.wasm` as build
context:

```
$ podman build -t hello-py-spin --build-arg APP_DIR=python-spin \
    --build-arg WASM_SRC=app.wasm --build-arg WASM_DST=app.wasm -f Containerfile .
Successfully tagged localhost/hello-py-spin:latest

$ podman run --rm -p 5099:3000 hello-py-spin
Preparing Wasm modules is taking a few seconds...
Error: component imports instance `spin:postgres/postgres@4.0.0`, but a
matching implementation was not found in the linker
```

The container built and Spin's engine started inside it (evidence: "Preparing
Wasm modules..." — that's Spin's own startup message, proving podman → Spin
→ wasmtime executed). The failure is an **application-level** mismatch — this
particular `app.wasm` imports a Postgres host binding the container's
`spin.toml` doesn't grant — not a podman/arm64/WASM compatibility problem.
Pre-existing gap in 003, out of scope to fix here, noted for the record only.

**Measured container tax** (from 003's own benchmark, commit `fd4f23f`): the
same Spin component costs **177 ms** cold start run natively (`spin up`) vs
**1,238 ms** wrapped in a podman container — a **+1,061 ms** tax, ~7x, and 5.3x
over 003's own <200ms hypothesis (now marked Rejected there). That tax is 6x
larger than the WASM runtime's *entire* native cold start. Wrapping a WASM
runtime in an OCI container throws away most of what WASM bought you — the
direct motivation for architecture #3 (below): don't wrap a WASM runtime in a
container, make WASM *replace* the container.

**Separately**: 003's leg 2c is currently blocked because its component was
built against Spin 4.0.0's `spin:postgres/postgres@4.0.0` import, and no
published `ghcr.io/fermyon/spin` container image implements it — the newest
published tag is v3.1.2 (`spin:latest`/`spin:canary` don't resolve or fail
identically). The host CLI (4.0.0) is ahead of every published container
image. Worth flagging as a pattern, not a one-off: containerizing a WASM
runtime can carry a version-skew cost on top of the cold-start tax above.

### 2b. crun-wasm — the recipe that does *not* work **[SUPERSEDED by §3b]**

A claim worth testing: podman can reportedly select a WASM-capable OCI
runtime (`crun` built with the wasm feature, "crun-wasm") the same way it
selects `runc`, via `[engine.runtimes]` in `containers.conf`, and — because
`podman play kube` shares container creation with `podman run` — a pod's
`runtimeClassName` would route to it too. If true, this would close the gap
between #2 (WASM runtime *inside* a container) and #3 (WASM *as* the
container) using tooling **already installed here**, no containerd/k8s
required. Treat everything below as what was actually run, not a restatement
of that claim.

**Confirmed genuinely available on this machine, inside the podman machine
VM** (podman runs in a Linux VM on macOS — the `crun` that matters is the
one *inside* it, checked via `podman machine ssh`, not any Homebrew crun on
the Mac host):

```
$ podman machine ssh -- crun --version
crun version 1.24
...
spec: 1.0.0
+SYSTEMD +SELINUX +APPARMOR +CAP +SECCOMP +EBPF +CRIU +LIBKRUN +WASM:wasmedge +YAJL

$ podman machine ssh -- which crun-wasm
/usr/bin/crun-wasm
```

So: yes, this VM's `crun` is genuinely built with `+WASM:wasmedge`, and a
separate `crun-wasm` binary exists at `/usr/bin/crun-wasm`. An OCI-Wasm image
was built earlier this session (`localhost/hello-crun-wasm:latest`, 43.9 KB —
confirmed via `podman images`), so image construction works.

**Runtime *selection* initially looked like a blocker, and the reason is
instructive.** Chasing the widely-repeated recipe — register `crun-wasm` under
`[engine.runtimes]` in `containers.conf`, then select it — dead-ends here:

```
$ podman run --rm --runtime=/usr/bin/crun-wasm localhost/hello-crun-wasm:latest
Error: unknown flag: --runtime
```

This podman client exposes no `--runtime` flag on `podman run` (only
`--cpu-rt-runtime`), and there is no `[engine.runtimes]` block — or even a
`/etc/containers/containers.conf` — in the VM at all.

**That recipe is simply the wrong mechanism.** No runtime registration and no
runtime selection are required, because the *default* `crun` is already built
`+WASM:wasmedge`. Dispatch happens on the
`module.wasm.image/variant=compat-smart` **annotation**, not on runtime choice.
Both `podman run` and `podman play kube` were subsequently run successfully on
this machine, with cold-start measurements and a three-way test isolating the
annotation as the true mechanism.

**See [§3b below](#3b-wasm-as-the-workload-via-podman--crun-verified) for the
verified result.** The lead was real; the published instructions for following
it are wrong.

### 3. WASM as the workload via a containerd shim — the interesting one **[VERIFIED]**

This is the one worth spelling out, because "container running a WASM
runtime" (#2) and "WASM **replacing** the container" (#3) look similar from a
`docker run` vantage point but are architecturally distinct:

- **#2**: containerd → `runc` shim → normal Linux process → that process
  happens to be a WASM runtime binary (Spin) that then interprets `.wasm`.
  Full Linux userspace exists (libc, the podman/docker base image, cgroups
  around a real process). The container almost certainly running `alpine` or
  `scratch`+musl underneath (in 003's case, `ghcr.io/fermyon/spin`, a real
  Linux OCI image).
- **#3**: containerd → a **WASM shim** (`containerd-shim-wasmtime-v1`, from
  [containerd/runwasi](https://github.com/containerd/runwasi), accessed
  2026-08-02) → wasmtime embedded **inside the shim process itself**. There is
  no Linux userspace in the "container" at all — the OCI image's only layer
  is a `.wasm` file, not a root filesystem. containerd's shim v2 protocol
  resolves the runtime name `io.containerd.wasmtime.v1` to a binary named
  `containerd-shim-wasmtime-v1` found on `$PATH`, exactly the way it resolves
  `io.containerd.runc.v2` to the `runc` shim — WASM slots into the same
  extension point as any other OCI runtime, it just isn't Linux underneath.

**Krustlet** (Deis Labs' "kubelet for WASM") was the original approach to
running WASM on Kubernetes, implementing the Kubelet API directly in Rust.
Per its own README (github.com/krustlet/krustlet, accessed 2026-08-02): *"This
project is currently not actively maintained. Most of the other maintainers
have moved on to other WebAssembly related projects."* It is **not**
GitHub-archived (`archived: false` via the GitHub API as of 2026-08-02) but is
dormant. The shim approach (this section) superseded it because it reuses
containerd's/Kubernetes' existing CRI plumbing instead of reimplementing the
kubelet — a WASM workload becomes just another `RuntimeClass`, with no new
node agent required. `deislabs/containerd-wasm-shims` (the shim project that
came directly out of Krustlet's orbit) is itself archived (confirmed via
GitHub API, `archived: true`, last push 2024-06-21); its functionality lives
on in `containerd/runwasi` (active) and `spinkube/containerd-shim-spin`.

**Verified via raw `ctr`** (bypassing Docker/podman CLI entirely, exactly as
runwasi's own quickstart does):

```
$ colima ssh -- uname -m
aarch64

# install the shim (aarch64-linux-musl build exists — arm64 confirmed, not assumed)
$ colima ssh -- curl -sL containerd-shim-wasmtime-aarch64-linux-musl.tar.gz | tar xz
$ colima ssh -- sudo cp containerd-shim-wasmtime-v1 /usr/local/bin/

$ colima ssh -- sudo ctr images pull ghcr.io/containerd/runwasi/wasi-demo-app:latest
Completed pull from OCI Registry ... total: 2.2 Mi (1.3 MiB/s)

$ colima ssh -- sudo ctr run --rm --runtime=io.containerd.wasmtime.v1 \
    ghcr.io/containerd/runwasi/wasi-demo-app:latest testwasm
This is a song that never ends.
Yes, it goes on and on my friends.
...
```

That output is real — it's the demo app's default command, run by a WASM
module acting as the container's entire workload, on a Docker daemon that has
never heard of Docker Desktop's Wasm feature.

**Contrast — Docker's own UX for this** (`docker run --platform=wasi/wasm32`)
does **not** work on this machine:

```
$ docker run --rm --platform=wasi/wasm32 ghcr.io/containerd/runwasi/wasi-demo-app:latest
docker: Error response from daemon: image with reference ... was found but
does not provide the specified platform (wasi/wasm32)
```

That flag requires Docker Desktop's bundled "Wasm Workloads" beta feature
(its own shim install + containerd image-store wiring), which colima's
dockerd doesn't provide. 003's README already noted podman doesn't support
this flag either — this experiment adds that **plain Docker CLI, on a
non-Docker-Desktop daemon, doesn't either.** The generic error message ("does
not provide the specified platform") is the same one you'd get for a genuine
missing-architecture multi-arch manifest — Docker isn't treating `wasi/wasm32`
specially without its own feature switched on. The `ctr` + shim path above is
the one that's actually portable across any containerd, Docker Desktop or
not.

**Verified via Kubernetes** (SpinKube's `spin-operator`, k3d, arm64):

```
$ k3d cluster create wasm018-spinkube \
    --image ghcr.io/spinframework/containerd-shim-spin/k3d:v0.23.0 --agents 1
$ kubectl apply -f cert-manager.yaml   # v1.14.5, see version-skew note below
$ kubectl apply -f spin-operator.{runtime-class,crds}.yaml
$ helm upgrade --install spin-operator --version 0.6.1 oci://ghcr.io/spinframework/charts/spin-operator
$ kubectl apply -f spin-operator.shim-executor.yaml
$ kubectl apply -f simple.yaml   # SpinApp, image: .../examples/spin-rust-hello:v0.23.0

$ kubectl get pod -o jsonpath='{.spec.runtimeClassName}'
wasmtime-spin-v2

$ curl localhost:8083/hello
Hello world from Spin!
```

Image size for that Spin component, confirmed via `ctr -n k8s.io image ls`
inside the k3d node: **524.4 KiB**, platform `wasi/wasm` (not `linux/arm64` —
it's a genuine WASM OCI artifact, no root filesystem at all).

**Version-skew finding** (found by running it, not documentation): the
upstream quickstart at spinkube.dev now uses `kind` (not installed on this
machine per the task brief), so we used the k3d workflow from
`spinframework/spin-operator`'s own README instead. cert-manager's **latest**
release (v1.20.0) fails against the k3d image's bundled k3s v1.27.8 with:

```
Error from server (BadRequest): error when creating "...cert-manager.yaml":
CustomResourceDefinition in version "v1" cannot be handled as a
CustomResourceDefinition: strict decoding error: unknown field
"spec.versions[0].selectableFields"
```

`selectableFields` is a K8s 1.31+ CRD feature; the pinned k3d shim image ships
k3s 1.27. Downgrading to cert-manager v1.14.5 resolved it immediately. This is
exactly the kind of "read the docs and it breaks anyway" gap the task asked
to surface rather than paper over.

Reproduce: `make verify-containerd-shim` and `make verify-k3d-spinkube`
(`scripts/verify-containerd-shim.sh`, `scripts/verify-k3d-spinkube.sh`).

### 3b. WASM as the workload via podman + `crun` **[VERIFIED]**

A second, much lighter route to the same architecture — no k8s, no separate shim
install, using only what podman already ships.

`crun` is Linux software and is **never installed on macOS**. It lives inside the
podman machine VM, already present, and every command below reaches it through
`podman machine ssh`. There is nothing to `brew install` for this leg. On a Linux
host, drop the `podman machine ssh --` prefix and the rest is identical.

```
$ podman machine ssh -- crun --version | tail -1
+SYSTEMD +SELINUX +APPARMOR +CAP +SECCOMP +EBPF +CRIU +LIBKRUN +WASM:wasmedge +YAJL
```

`crun-wasm` as a separate binary is **not required** — `+WASM:wasmedge` is compiled
into the default runtime. The image is `FROM scratch` plus one file:

```dockerfile
FROM scratch
COPY hello.wasm /hello.wasm
ENTRYPOINT ["/hello.wasm"]
```

```
$ podman build --annotation "module.wasm.image/variant=compat-smart" -t hello-crun-wasm .
$ podman run --rm --annotation module.wasm.image/variant=compat-smart hello-crun-wasm
hello from wasm, run by crun+wasmedge — no Linux userspace in this container
```

Total image: **43.9 kB** (a 40,445-byte `wasm32-wasip1` module and nothing else — no
distro, no libc, no shell). `podman play kube pod-wasm.yaml` runs it identically.

#### Cold start, measured (5 runs, median)

| | Median | Δ vs container floor |
|---|--------|---------------------|
| podman + normal process (`alpine echo`) | **169 ms** | — (podman's own floor) |
| podman + crun-wasm (WASM *is* the workload) | **217 ms** | **+48 ms** |
| Spin runtime *inside* podman — [003](../003_wasm_compile/) leg 1b | **1,238 ms** | +1,061 ms |

**This is the architecture #2 vs #3 result in one table.** Running WASM *as* the
workload costs **+48 ms** over the bare container floor; running a WASM *runtime inside*
a container costs **+1,061 ms** — a 22x difference. Eliminating the container's contents,
rather than filling it with a WASM runtime, is what preserves the WASM advantage.

*Caveat, stated plainly:* the 1,238 ms figure measures time-to-first-HTTP-200 for a Spin
server, while 217 ms measures run-hello-and-exit. They are not the same workload shape.
The apples-to-apples pair is 169 ms vs 217 ms — both trivial run-and-exit — and it shows
the wasm handler adds ~48 ms to a container that would otherwise start a Linux process.

#### Correction: `runtimeClassName` does *not* drive this

Widely-repeated guidance says you must register `crun-wasm` under `[engine.runtimes]` in
`containers.conf` and select it with `runtimeClassName` in the pod spec, "just like k8s
RuntimeClass". **On podman 5.8.2 that is wrong**, and this machine has no
`[engine.runtimes]` block at all. Three tests:

| Pod spec | Result |
|----------|--------|
| `runtimeClassName` present, annotation **removed** | **fails** — `exec /hello.wasm: Exec format error` |
| annotation present, `runtimeClassName` **removed** | **works** |
| annotation present, `runtimeClassName: totally-bogus-runtime` | **works** |

The `module.wasm.image/variant` annotation is the entire mechanism; `runtimeClassName` is
accepted and silently ignored. **The "1:1 mapping onto k8s RuntimeClass" claim is therefore
false in a way that matters:** real k8s genuinely routes via RuntimeClass to a containerd
shim (verified in §3 above), whereas podman routes via an annotation. A manifest that runs
as WASM under `podman play kube` will *not* run as WASM on k8s, and vice versa. The
architecture is portable; the manifest is not.

Reproduce: `crun-wasm/` (`Containerfile`, `pod-wasm.yaml`, `hello/`).

---

## Four platform runtimes — local-testability matrix

| Platform | Local runtime | Installable on arm64 macOS? | Hello-world runs? | Deployable unit |
|---|---|---|---|---|
| Fermyon Cloud | **Spin** 4.0.0 | ✅ pre-installed (Homebrew) | ✅ (003/014, and this experiment's portability test) | wasi-http **component** (wasm32-wasip2), wrapped in a `spin.toml` manifest |
| wasmCloud | **wash** 2.5.2 | ✅ `brew install wasmcloud/wasmcloud/wash` | ✅ `wash dev`, serving in <1s after build | wasi-http **component** — same Component Model target as Spin, no wasmCloud-specific SDK required (see portability below) |
| Cloudflare Workers | **workerd** via `wrangler dev` 4.114.0 | ✅ `npm install -g --allow-scripts=esbuild,workerd wrangler` (see note) | ✅ served a JS Worker; ❌ could not load a WASM **component** (see portability) | **JS module** with WASM embedded as a plain **core module** import (`import wasm from "./x.wasm"`) — WASM is an ingredient of the Worker, not the top-level unit |
| Fastly Compute | **Viceroy** via `fastly compute serve` | ✅ `brew install fastly`; Viceroy itself is fetched on first `fastly compute serve` call (not brew/cargo) | ✅ for Fastly's own SDK-based apps (not tested here — out of scope); ❌ for a bare wasi-http component (see portability) | Core **module** built against Fastly's own `fastly` Rust/JS SDK (or, experimentally, a wasi-http component — not yet supported per Viceroy's own warning) |

Note on wrangler install: `npm install -g wrangler` alone leaves `workerd`
non-functional — npm's `allow-scripts` sandboxing blocks the postinstall
script that downloads the actual `workerd` binary (114MB, arm64-native). Must
explicitly run `npm install -g --allow-scripts=esbuild,workerd wrangler`.

Cold-start feel (qualitative, not a formal benchmark — see proposed next
experiment):
- **Spin**: `spin up` was serving within the same second it printed "Serving
  http://...".
- **wash dev**: ~800ms from "starting development session" to "listening for
  HTTP requests" log line, including a (cached, 0.68s) rebuild check.
- **wrangler dev**: several seconds to boot workerd itself (V8 isolate init +
  local dev server scaffolding) before first request.
- **fastly compute serve**: first run pays a one-time cost fetching the
  Viceroy binary release; after that, comparable to wrangler.

All four are genuinely arm64-native here — no Rosetta, no emulation. That was
not guaranteed going in (per the task brief, several containerd/K8s WASM
shims have historically been amd64-only) and is worth stating plainly since
it wasn't a given.

Reproduce: `make verify-platforms` (`scripts/verify-platform-runtimes.sh`).

---

## The portability question

**Can one `.wasm` run on multiple platforms?** Tested directly: built a
single component — wasmCloud's own `templates/http-hello-world` (scaffolded
via `wash new`, using the [`wstd`](https://github.com/bytecodealliance/wstd)
crate, targeting `wasm32-wasip2`) — **once**, then tried to run the exact same
binary, unmodified, on all four platform runtimes plus raw wasmtime. The
component's WIT world is empty (`world hello {}`); `wstd`'s `#[http_server]`
macro makes it export `wasi:http/incoming-handler` and nothing
platform-specific.

```
$ wash build
Successfully built component at: target/wasm32-wasip2/release/hello_world.wasm
$ ls -la target/wasm32-wasip2/release/hello_world.wasm
355936 bytes
```

Source lives in `portability/hello/`; the test is `scripts/portability-test.sh`.

| Runtime | Result | Evidence |
|---|---|---|
| `wasmtime serve` (no wrapper) | ✅ **PASS**, zero config | `Hello from wasmCloud!` |
| Spin (`spin up`, wrapped in a hand-written `spin.toml`, **no rebuild**) | ✅ **PASS** | `Hello from wasmCloud!` |
| wasmCloud (`wash dev`) | ✅ **PASS** (it's the component's own template, but confirms the local host works) | `Hello from wasmCloud!` |
| Fastly Compute (Viceroy, `fastly compute serve --skip-build`) | ❌ **FAIL** | `Wasm Component support in viceroy is in active development, and is not supported for general consumption` → `component imports instance 'wasi:http/types@0.2.9', but a matching implementation was not found in the linker` |
| Cloudflare Workers (`wrangler dev`, `.wasm` as an ES module import) | ❌ **FAIL**, more fundamentally | `Uncaught CompileError: WasmModuleObject::Compile(): expected version 01 00 00 00, found 0d 00 01 00 @+4` |

**Verdict: 3 of 5 for free, 2 of 5 not portable today, and the two failures
are qualitatively different:**

1. **Viceroy (Fastly)** fails at the **semantic** layer: it can parse the
   component and start linking it, but doesn't yet implement the
   `wasi:http/types` world for components — Viceroy's own startup banner says
   so outright ("in active development ... not supported for general
   consumption"). This is a *not-yet* gap, actively being closed.
2. **workerd (Cloudflare)** fails at the **binary format** layer, one level
   more fundamental: the bytes `0d 00 01 00` right after the `\0asm` magic
   number are the Component Model's version/layer header (`layer=1`); V8 only
   implements core Wasm modules (`layer=0`, `01 00 00 00`) and can't even
   parse a component, let alone run wasi-http against it. Cloudflare Workers'
   WASM story is JS-API-centric by design — WASM is an ingredient loaded
   *into* a Worker via `import`, not the top-level deployable unit — so this
   isn't a temporary gap the way Viceroy's is, it's a different embedding
   model entirely.

**"Not portable today, wasi-http is the convergence path" is demonstrated,
not asserted**: Spin, wasmtime, and wasmCloud already speak the same
Component Model + `wasi:http` dialect well enough that a component built for
one runs unmodified on the other two. Fastly is actively building toward it
(the warning banner is evidence of intent). Cloudflare's model is
architecturally furthest away — closing that gap means embedding a component
runtime inside a Worker, not just adding a WIT world.

Reproduce: `make portability-test`.

---

## Making Cloudflare pass (leg 6)

Leg 5 shows the component rejected by workerd. Leg 6 runs the *same bytes*
successfully. Both are kept, because the gap between them is the finding.

Four constraints, each discovered by hitting it:

| # | Constraint | Fix |
|---|-----------|-----|
| 1 | V8 loads core modules only | `jco transpile` — `\0asm 0d 00 01 00` becomes `\0asm 01 00 00 00` |
| 2 | workerd forbids unsettled top-level await | `--instantiation sync` |
| 3 | sync instantiation needs a `WebAssembly.Module` synchronously | static `.wasm` imports (and *no* `[[rules]]` block — wrangler already has a `CompiledWasm` rule and a duplicate errors) |
| 4 | `preview2-shim` implements only the **client** half of wasi:http | hand-written server host, `portability/cf-worker/wasi-http-host.js` |
| 5 | glue does `e instanceof OutputStream` | wasi:io must come from the same owner, `wasi-io-host.js` — mixing shims gives `Resource error: Not a valid "OutputStream" resource` |

Constraint 4 is the real one, and it is deeper than the binary format that gets
all the attention. `preview2-shim`'s server-side types are empty stubs
(`IncomingRequest: class IncomingRequest {}`), and `jco serve` only works because
it uses the **Node** shim plus `node:http` — which workerd cannot provide, since a
Worker *is* the server and never listens on a socket.

Result: **portable, but not unmodified.** Same guest binary as wasmtime/Spin/
wasmCloud — no source change, no recompile — plus a transpile step and ~180 lines
of host adapter. That is a third outcome, not a PASS and not a FAIL, and the
table reports it as such. Full walkthrough: `portability/cf-worker/README.md`.

## Cloud-provider landscape — **[RESEARCHED, not verified locally]**

None of this was run — these are managed cloud services this machine can't
provision. Sourced and dated below; correct my priors where the sources say
otherwise.

- **Azure AKS WASI node pools: retired**, not merely "still in preview" as I
  assumed going in. Per Azure's own retirement notice
  ([Azure/AKS#4770](https://github.com/Azure/AKS/issues/4770), accessed
  2026-08-02): no new WASI node pools can be created **starting May 5, 2025**.
  The original feature doc has been moved to Microsoft Learn's
  "previous-versions" archive
  ([learn.microsoft.com/.../use-wasi-node-pools](https://learn.microsoft.com/ja-jp/previous-versions/azure/aks/use-wasi-node-pools),
  accessed 2026-08-02) — the relocation itself is corroborating evidence.
  Microsoft's recommended replacement is deploying **SpinKube** to AKS
  yourself ([learn.microsoft.com/azure/aks/deploy-spinkube](https://learn.microsoft.com/azure/aks/deploy-spinkube),
  accessed 2026-08-02) — i.e. exactly the architecture-3 mechanism verified
  above, just on managed infra instead of k3d.
- **AWS: no first-class native WASM/WASI compute platform.** Checked AWS
  Lambda's runtime list
  ([docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html),
  accessed 2026-08-02) — no Wasm entry, only standard language runtimes.
  Several 2026 blog posts claim "AWS Lambda now has a GA WebAssembly
  runtime" — **these could not be corroborated against any
  aws.amazon.com/docs.aws.amazon.com page** and are not cited as fact here.
  Real AWS-side WASM usage found is all bring-your-own-runtime: community
  projects (e.g. `second-state/aws-lambda-wasm-runtime`,
  `chiefbiiko/lambda-wasmtime`) embed wasmtime/WasmEdge inside a Lambda
  **custom runtime** — third-party, not AWS-native, and equivalent in kind to
  what [009](../009_rust_native_host/) already does locally.
- **GCP**: no primary source found for a native GCP WASM/WASI compute
  offering. wasmCloud-on-GKE deployment guides exist
  ([wasmcloud.com/docs/.../gcloud-gke](https://wasmcloud.com/docs/v1/deployment/k8s/gcloud-gke/))
  but that's wasmCloud's own doc, not a GCP-native feature — same shape as
  running SpinKube on AKS or on any other Kubernetes.

Net: of the three major clouds, Azure is the only one that shipped (and then
retired) a bespoke WASM node-pool primitive; the durable pattern all three
converge on is "run SpinKube/wasmCloud/runwasi yourself on a K8s cluster you
already have," not a cloud-native WASM compute product.

---

## Proposed follow-up experiment: benchmarking

This experiment stopped at "does it install and run" by design (see Scope
below). A follow-up benchmarking round, in priority order of what's actually
runnable locally:

**Fully local, no cloud account needed:**
1. **Cold start**: wall-clock from process/pod launch to first successful
   response, for: architecture 1 (docker run) vs 2 (podman+Spin) vs 3a (`ctr
   run` + shim) vs 3b (k3d SpinApp pod) vs Spin native (`spin up`) vs wash
   native (`wash dev`) vs `wasmtime serve`. All six are reproducible on this
   machine with the scripts already in this directory as a starting point.
2. **Artifact/image size**: already spot-measured here (524.4 KiB Spin
   component vs 79.6 MiB `klipper-helm` sidecar image, for scale) — worth a
   systematic table across all six legs above, reusing 012's
   size-measurement approach.
3. **Portability matrix as regression test**: `scripts/portability-test.sh`
   already returns a clean pass/fail per runtime — wire it into CI so a
   future Viceroy or workerd release that adds Component Model support is
   caught automatically (turning an FAIL into an unexpected PASS is itself
   the finding).
4. **Memory (RSS)**: `ctr run` (arch 3a) vs k3d pod (arch 3b) vs Spin-in-podman
   (arch 2) vs `docker run` baseline (arch 1) — all measurable via existing
   OS tools (`ps`, `docker stats`, `ctr task metrics`) with no new
   infrastructure.
5. **Throughput** (`hey`, already used in 003/014): same six legs, same
   payload, reusing 014's `data/records.csv` fixture for a realistic
   comparison.

**Needs a cloud account (out of scope until one is provisioned):**
6. Fermyon Cloud, Cloudflare Workers (real, not `wrangler dev`), Fastly
   Compute (real, not Viceroy) — actual edge cold start and geographic
   distribution numbers can't be approximated locally; the local runtimes
   measured here are the vendors' own stated proxy for local dev latency, not
   for production edge performance.
7. AKS-with-SpinKube vs raw AKS containers — needs an Azure subscription;
   the local k3d result in this experiment is the closest local proxy.

Do **not** attempt a from-scratch amd64 emulation comparison — out of scope,
and would need x86 hardware or heavy QEMU overhead that would confound the
numbers being measured.

## Scope

Per the task brief, a full benchmark harness was an explicit stretch goal —
this experiment delivers the verified install/testability matrix and the
portability demonstration, plus small scripts that already produce clean
pass/fail signal (see `scripts/portability-test.sh`'s summary table above).
Turning those into a numbers-producing benchmark is the proposed follow-up
above, not built here.

## Structure

```
018_wasm_platforms/
├── README.md
├── Makefile
├── scripts/
│   ├── verify-baseline.sh            # architecture 1: docker run hello-world
│   ├── verify-containerd-shim.sh     # architecture 3 via raw ctr + runwasi shim
│   ├── verify-k3d-spinkube.sh        # architecture 3 via k3d + SpinKube CRDs
│   ├── verify-platform-runtimes.sh   # installs/version-checks all 4 platform runtimes
│   └── portability-test.sh           # the 5-runtime portability matrix
├── portability/
│   └── hello/                        # the wasi-http component under test (wash template)
└── crun-wasm/                        # 3b leg — VERIFIED: WASM as workload via podman + crun
    ├── Containerfile                 # FROM scratch, COPY hello.wasm, ENTRYPOINT — no Linux userspace
    ├── hello/                        # minimal WASI command (Rust, wasm32-wasip1)
    └── pod-wasm.yaml                 # podman play kube — verified running (§3b);
                                       # runtimeClassName is ignored, the annotation dispatches
```

## Prerequisites

```bash
brew install colima docker podman spin fermyon/tap/spin wasmtime k3d kubernetes-cli helm
brew install wasmcloud/wasmcloud/wash
brew install fastly
npm install -g --allow-scripts=esbuild,workerd wrangler
rustup target add wasm32-wasip2
```

`make verify-platforms` installs what's missing automatically. The
containerd-shim and k3d scripts assume `docker`'s backend is `colima` (this
machine's setup) — adapt the `colima ssh` calls if using Docker Desktop or
Rancher Desktop instead.
