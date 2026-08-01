# Experiment 011 — Mastermind CLI, real WASI stdin, `wasm32-wasip1`

Direct answer to a specific question raised while building experiment 010: MVL's
own `mvl build --backend=wasm` can't run `mvl-lang/mvl/examples/mastermind`'s
interactive CLI (`main.mvl`) because its `runtime` import namespace has no stdin at
all — `stdin`/`read_line` are undefined under that backend, confirmed directly (see
experiment 010's README). That's a gap in *MVL's specific WASM backend design*, not
a fundamental limitation of WASM or WASI. This experiment proves it: the same game,
reimplemented in pure Rust, compiled to `wasm32-wasip1`, run under **real** WASI
with **real** interactive stdin — no custom import namespace, no shim, standard
WASI `fd_read` doing exactly what it's designed to do.

## What's here

- **`guest/`** — the Mastermind CLI itself, compiled to `wasm32-wasip1`. Not a fresh
  design: `score_guess`/`count_blacks`/`count_color_at_mismatch` are line-for-line
  ports of `mvl-lang/mvl/examples/mastermind/code.mvl`'s algorithms (same
  mismatch-position restriction on both sides of the white-peg tally, same `min()`
  to avoid double-counting), and the game loop/prompts mirror `main.mvl`'s
  `read_guess`/`main` shape. Uses plain `std::io::stdin()` — under `wasm32-wasip1`
  this compiles straight through to real WASI `fd_read` calls, no special handling
  needed on the guest side at all.
- **`host/`** — an embedded Rust host (same `wasmtime` crate pattern as experiment
  009) that runs the guest with **explicit** WASI stdio wiring, so the actual wiring
  code is visible and small:

  ```rust
  let mut linker: Linker<WasiP1Ctx> = Linker::new(&engine);
  preview1::add_to_linker_sync(&mut linker, |ctx| ctx)?;   // registers fd_read, fd_write, etc.

  let wasi = WasiCtxBuilder::new()
      .inherit_stdin()   // guest's fd 0 -> this process's real stdin
      .inherit_stdout()
      .inherit_stderr()
      .inherit_args()
      .build_p1();
  ```

  This — a WASI context with stdio inherited, registered into a `Linker` before
  instantiation — is the entire piece missing from MVL's WASM backend. Nothing
  exotic; a few lines against a stable, standard API (`wasmtime-wasi` 27,
  `preview1::add_to_linker_sync` — the flat-ABI preview1 entry point, not the
  newer component-model preview2 API, since `wasm32-wasip1` is the older core-module
  ABI).

Both `wasmtime run guest/....wasm` directly and the embedded host produce identical
behavior — the host exists to make the wiring explicit and inspectable, not because
`wasmtime run` needs help; it already wires preview1 stdio by default.

## Proof: genuinely interactive, not just a piped file

A whole canned input file piped into `wasmtime run` would prove the mechanics work,
but not that the process is actually *blocking on real reads* rather than the input
having been available all along. Verified with a real pty (`pty.openpty()` +
`select()` with a timeout), sending one line at a time and confirming no output
arrives between prompts until a line is actually sent — a genuine send/receive
round-trip, not a batch:

```
=== output before any input ===
...
Attempt 1 of 10 -- your guess:
                                    <- process blocks here, confirmed via select() timeout
=== sending '1 2 3 4' ===
1 2 3 4
  -> blacks: 1  whites: 1
Attempt 2 of 10 -- your guess:
                                    <- blocks again
=== sending '6 5 4 3' ===
6 5 4 3
  -> blacks: 0  whites: 3
...
```

Confirmed for both the `wasmtime run` path and the embedded host. Feedback values
hand-verified against the actual generated secret in both runs.

## A real gotcha: stdout buffering under WASI

Rust's `stdout()` is block-buffered by default when not attached to a TTY — which a
WASI-hosted process, from the guest's point of view, never is. Without an explicit
`.flush()` after every prompt, a prompt can sit in the buffer while the process
blocks on `read_line`, making a genuinely-working interactive session *look* hung
(output arrives all at once, batched, whenever the buffer happens to fill or the
process exits). Every `say!` in `guest/src/main.rs` flushes explicitly — worth
calling out since it's an easy way to build something that "works" under a piped
test but appears broken interactively.

## Usage

```bash
./build.sh

# Either run path — pick one:
wasmtime run guest/target/wasm32-wasip1/release/mastermind-guest.wasm
./host/target/release/mastermind-host
```

Both read real stdin interactively. Non-interactive verification:

```bash
printf "1 2 3 4\n2 3 4 5\n" | wasmtime run guest/target/wasm32-wasip1/release/mastermind-guest.wasm
```

## What this means for MVL

Making `mvl-lang/mvl/examples/mastermind` (or any MVL program using `std.io.stdin`)
actually run under `--backend=wasm` would need: (1) wiring `fd_read` (and friends)
into whatever host runs the compiled module — `mvl-playground`'s browser Worker
currently has no stdin source to wire it to anyway, so this would need a different
host, not just a runtime patch — and (2) `code.mvl`'s own `parse_guess` fixed, since
it currently traps on call regardless of where its input comes from (see experiment
010's README — "contained unsupported constructs"). Neither is a WASM/WASI
limitation; both are specific, addressable gaps in MVL's current WASM backend and
runtime, demonstrated concretely here rather than asserted.

## Solver — run sideways

`solve.py` is a pure-Python companion tool: play the WASM game (or a physical
board) in one terminal, run the solver in another. Feed it every guess and its
feedback; it filters the possibility space and suggests the best next guesses
ranked by worst-case elimination power.

```bash
# after round 1: guessed 1 1 2 2, got 1 black 0 white
python3 solve.py 1 1 2 2 1 0

# after round 2: add the new round's 6 numbers
python3 solve.py 1 1 2 2 1 0  3 3 4 4 0 1

# or via make
make solver ARGS="1 1 2 2 1 0  3 3 4 4 0 1"
```

Each group of 6 numbers is one round: 4 colors (1–6) + blacks + whites.
Use `-c 8` for 8-color variants, `-p 5` for 5-position boards.

## Structure

```
011_mastermind_cli_wasi/
├── README.md
├── build.sh
├── solve.py               # Python solver — run alongside the game
├── guest/
│   ├── Cargo.toml
│   └── src/main.rs        # the game — real stdin, compiled to wasm32-wasip1
└── host/
    ├── Cargo.toml
    └── src/main.rs        # embedded wasmtime host, explicit WASI stdio wiring
    # */target/, Cargo.lock are build.sh output, gitignored
```
