# ADR Index

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-c4-experiment-001-hello-world.md) | C4 context — experiment 001 hello world benchmark | Accepted |
| [0002](0002-archetype-browser-worker-wasi-shim.md) | Archetype — browser Worker + vendored WASI shim | Accepted |
| [0003](0003-archetype-custom-hand-rolled-abi.md) | Archetype — custom hand-rolled import namespace (non-WASI ABI) | Accepted |
| [0004](0004-archetype-prebuilt-server-http-blackbox.md) | Archetype — pre-built server consumed as an HTTP black box | Accepted |
| [0005](0005-archetype-embedded-runtime-library.md) | Archetype — embedded runtime as a library (in-process, native host) | Accepted |
| [0006](0006-archetype-interpreter-in-wasm.md) | Archetype — interpreter-in-WASM (ship the runtime, not the program) | Accepted |
| [0007](0007-archetype-decision-guide.md) | Decision guide — choosing among the six archetypes | Accepted |
| [0008](0008-archetype-guest-owned-sockets.md) | Archetype — guest-owned sockets via wasi:sockets | Accepted |
| [0009](0009-isolation-models-browser-context-vs-wasi-capabilities.md) | Isolation models — browser contexts vs WASI capabilities | Accepted |

ADRs 0002–0006, 0008 each document one recurring architecture observed across this
repo's experiments — not a single decision made once, but a *shape* that keeps
reappearing, with the trade-offs each occurrence actually measured. 0007 ties them
together into one comparison. 0009 is a different genre again: a cross-cutting
comparison of the two isolation models the archetypes rely on, rather than an
archetype itself. 0001 predates this numbering scheme (a per-experiment
prompt-contract C4 doc, a different genre — kept as-is, not renumbered).

See `RESEARCH.md` for underlying WASM/WASI specification research (a
separate, actively-updated document, not an ADR).
