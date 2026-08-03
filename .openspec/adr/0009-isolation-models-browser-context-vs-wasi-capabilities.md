# Isolation models: browser contexts vs WASI capabilities

> Closes the two analysis tasks left open on #11: *document the security
> guarantees of browser-level isolation*, and *compare with the WASI sandbox
> model*. The measurement half of #11 was answered by
> [experiment 002](../../experiments/002_chromium_sandbox/) (legs 2b/3b/4b);
> what remained was working out **what the overhead actually buys**.

Status: Accepted

## The question

Experiment 002 measured that a fresh `BrowserContext` per request costs **~950 ms
and ~340 MB** (H3, H5). Hypothesis H10 on #11 assumed that price bought
"security guarantees" without ever saying which. If the guarantee is weak, the
architecture is simply expensive. If it is strong, the cost may be justified for
genuinely untrusted code.

So: what does a `BrowserContext` isolate, and how does that compare to what a
WASI runtime isolates?

## What a BrowserContext actually isolates — measured, not assumed

The intuitive answer is "storage" — separate cookie jar, `localStorage`,
`IndexedDB`, cache, permissions. That is true, and it is what the Playwright
documentation emphasises. It is also **not the important part**.

Chromium allocates renderer processes per `SiteInstance`, and `SiteInstance`s are
not shared across `BrowserContext`s. So each context should get its own renderer
process even for the *same* origin — the case where sharing would be legitimate.
Measured on this machine (system Chrome, Playwright, all contexts loading one
identical origin, counting `--type=renderer` processes):

| Contexts, same origin | Renderer processes added |
|----------------------:|-------------------------:|
| 1 | 2 |
| 2 | 3 |
| 3 | 4 |
| 4 | 5 |

One renderer process per context, linearly. **A `BrowserContext` is an OS process
boundary, not merely a storage boundary.** That also explains 002's H5 result
(~340 MB per context, against a predicted ~50 MB): each context is a whole
renderer process, not a lightweight namespace inside one.

That makes the guarantee substantially stronger than "storage is separate":

- **OS process isolation.** A compromised guest in one context cannot read
  another context's address space without first defeating the kernel boundary.
- **The renderer sandbox.** Chrome's renderer runs under seccomp-bpf on Linux and
  the macOS sandbox — no filesystem, no network syscalls, brokered IPC only.
  Escaping the guest lands you in one of the most heavily attacked and hardened
  sandboxes in commodity software.
- **Site Isolation and Spectre mitigations** apply per renderer, so cross-origin
  reads are additionally blocked by the browser's own web-security model.

## What WASI isolates instead

A WASI runtime (wasmtime, embedded per [ADR-0005](0005-archetype-embedded-runtime-library.md))
guarantees something different in kind:

- **Deny by default, no ambient authority.** A module can only touch what the
  host handed it. There is no global filesystem namespace to reach into — a
  guest cannot name `/etc/passwd`, because it has no directory capability at all
  unless one was preopened.
- **Per-capability granularity.** `--dir` grants one directory as an fd,
  `-S inherit-network` grants sockets, `--env` grants named variables. Each is an
  individual, auditable grant rather than a posture.
- **Enforcement is the import surface.** The runtime *is* the security boundary:
  the guest can only call functions the host chose to link.

And, critically, what it does **not** give you: by default the guest runs **in
the host's process**. Memory safety comes from WASM's own model — linear memory,
bounds-checked, no raw pointers — not from the OS. A bug in the runtime's own
implementation of an import is a bug inside your process.

## The comparison

| | `BrowserContext` (Chrome) | WASI capabilities (wasmtime) |
|---|---|---|
| Boundary | **OS process + renderer sandbox**, one per context (measured above) | import surface, **inside the host process** |
| Default posture | **ambient** — `fetch`, timers, storage APIs all present | **deny-all** — nothing unless granted |
| Granularity | per context / profile | per capability: fd, socket, env var |
| If the guest escapes WASM | into a sandboxed renderer, then the OS sandbox | into the host process |
| Limits what the guest can *ask for* | weakly — the web platform is large | **strongly** — it cannot name what it wasn't given |
| Cost (002, 009) | **~950 ms, ~340 MB** per context | **~40 ms, ~20 MB** per instance |
| Enforced by | Chromium's process model | the runtime's linker |

**They are strong in opposite directions, and this is the finding.** The browser
gives the stronger *containment* primitive — a real OS process behind a hardened
sandbox — while offering a weak *capability* posture, because the web platform is
ambient and enormous. WASI gives the stronger *capability* posture — a guest
cannot even express a request for something it wasn't granted — while offering
weaker containment, since it shares the host's process by default.

So H10 on #11 was not wrong, but it was imprecise. The ~950 ms does buy a real
security guarantee. It just buys the *containment* kind, at roughly 24x the cold
start and 17x the memory of the alternative, while leaving the guest with ambient
access to a much larger API surface.

## Consequences

**For a multi-tenant WASM host, prefer WASI capabilities.** Deny-by-default at
~40 ms is a better match for "run this stranger's function" than
ambient-authority-behind-a-process-wall at ~950 ms. Attack surface matters more
than blast radius when the surface is the whole web platform.

**Reach for browser contexts only when the guest genuinely needs the web
platform** — DOM, canvas, WebGL, real `fetch` semantics — and you are willing to
pay a renderer process per tenant for it. That is a rendering requirement wearing
an isolation costume; the isolation is a side effect.

**Do not stack them and assume the costs compose favourably.**
[Experiment 002](../../experiments/002_chromium_sandbox/) leg 5a measured that
headless Chromium has a **~600 ms / ~240 MB floor even with Pyodide removed and
native WASM inside** — slower to cold-start than a plain container. The browser's
isolation is strong, but it is not free, and it is not the cheapest way to obtain
a process boundary. If a process per tenant is what you want, a WASI runtime in a
forked process gets you both properties for far less.

## Evidence

- Renderer-process counts: measured here against system Chrome via Playwright,
  four same-origin contexts, counting `--type=renderer`.
- ~950 ms per-request context cost, ~340 MB per context:
  [002](../../experiments/002_chromium_sandbox/) H3, H5.
- ~600 ms / ~240 MB Chromium floor with native WASM:
  [002](../../experiments/002_chromium_sandbox/) leg 5a.
- ~40 ms / ~20 MB embedded wasmtime:
  [009](../../experiments/009_rust_native_host/), and
  [ADR-0005](0005-archetype-embedded-runtime-library.md).

## Not covered

Side-channel resistance is asserted by neither model in a way this repo has
tested. The browser ships Spectre mitigations and requires COOP/COEP before
handing out `SharedArrayBuffer` (see
[006](../../experiments/006_worker_kill_switch/)); wasmtime does not coarsen
timers by default. Neither claim was measured here, and a timing-attack
experiment would be a separate piece of work.
