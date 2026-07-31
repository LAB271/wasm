// mastermind-host — an embedded Rust host running the mastermind-guest
// wasm32-wasip1 binary, with EXPLICIT WASI stdio wiring.
//
// This is the piece MVL's own `mvl build --backend=wasm` doesn't have: its
// `runtime` import namespace (~60 hand-written string/array/option/result/
// map functions, see experiment 008) has no stdin at all, so `stdin`/
// `read_line` are undefined under that backend. Real interactive I/O under
// WASM isn't impossible — WASI already solves it, and it's exactly these
// few lines: a WasiCtx with stdio inherited, wired into a Linker before
// instantiation.
use wasmtime::{Config, Engine, Linker, Module, Store};
use wasmtime_wasi::preview1::{self, WasiP1Ctx};
use wasmtime_wasi::WasiCtxBuilder;

const WASM_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../guest/target/wasm32-wasip1/release/mastermind-guest.wasm"
);

fn main() -> anyhow::Result<()> {
    let mut config = Config::new();
    config.wasm_backtrace_details(wasmtime::WasmBacktraceDetails::Enable);
    let engine = Engine::new(&config)?;

    let mut linker: Linker<WasiP1Ctx> = Linker::new(&engine);
    // THE wiring: preview1 WASI syscalls (fd_read, fd_write, clock_time_get,
    // etc.) registered into the linker so the guest's `call $fd_read` (and
    // everything Rust's std::io::stdin() compiles down to) resolves to a
    // real implementation instead of an unsatisfied import. wasm32-wasip1
    // (this guest's target) uses the "preview1" flat-ABI WASI, not the
    // component-model preview2 — hence `preview1::add_to_linker_sync`, not
    // the crate-root `add_to_linker_sync` (which is preview2/component-only).
    preview1::add_to_linker_sync(&mut linker, |ctx| ctx)?;

    // inherit_stdin()/inherit_stdout()/inherit_stderr(): the guest's fd 0/1/2
    // are wired directly to THIS process's real stdio — genuine fd_read
    // against the terminal (or whatever's piped into this process), not a
    // simulated/buffered fake.
    let wasi = WasiCtxBuilder::new()
        .inherit_stdin()
        .inherit_stdout()
        .inherit_stderr()
        .inherit_args()
        .build_p1();

    let mut store = Store::new(&engine, wasi);
    let module = Module::from_file(&engine, WASM_PATH)?;
    let instance = linker.instantiate(&mut store, &module)?;

    // wasm32-wasip1 binaries expose their entry point as `_start`, the same
    // convention `wasmtime run` itself uses under the hood.
    let start = instance.get_typed_func::<(), ()>(&mut store, "_start")?;
    match start.call(&mut store, ()) {
        Ok(()) => Ok(()),
        Err(e) => {
            // A clean WASI exit (including a nonzero process::exit) surfaces
            // as a trap carrying an I32Exit — not a real crash. Anything
            // else is a genuine guest fault and should propagate.
            if let Some(exit) = e.downcast_ref::<wasmtime_wasi::I32Exit>() {
                std::process::exit(exit.0);
            }
            Err(e)
        }
    }
}
