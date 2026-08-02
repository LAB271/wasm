// Minimal native wasmtime host for experiment 019.
//
// Two jobs:
//   1. Satisfy the `env.host_log` import our test module declares, so any
//      tier's .wasm can be instantiated and driven from a Rust host exactly
//      like it would be from a JS host in the browser/Node (H5).
//   2. Call an exported function and print either the return value or, if
//      it traps, the trap's error chain with `wasm_backtrace_details`
//      enabled — this is what H2 (name-section-derived stack traces) checks
//      against, on the wasmtime side.
//
// Usage: wasm-debug-host <path-to.wasm> <export-fn> <u32-arg>
use std::env;
use wasmtime::*;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 4 {
        eprintln!(
            "usage: {} <path-to.wasm> <export-fn> <u32-arg>",
            args.first().map(String::as_str).unwrap_or("wasm-debug-host")
        );
        std::process::exit(2);
    }
    let wasm_path = &args[1];
    let func_name = &args[2];
    let arg: u32 = args[3].parse().expect("arg must be a u32");

    // wasm_backtrace_details controls whether trap backtraces resolve wasm
    // frames to names (from the name section) / source locations (from
    // DWARF) or print raw `wasm-function[N]` labels. "Auto" (the default)
    // only does this when debug info is present; we force it on so the
    // *lack* of names in stripped tiers is visible as "wasm-function[N]"
    // rather than the backtrace silently being empty.
    let mut config = Config::new();
    config.wasm_backtrace_details(WasmBacktraceDetails::Enable);
    config.debug_info(true);
    let engine = Engine::new(&config)?;

    let module = Module::from_file(&engine, wasm_path)?;
    let mut linker = Linker::new(&engine);
    linker.func_wrap(
        "env",
        "host_log",
        |mut caller: Caller<'_, ()>, ptr: u32, len: u32| {
            let memory = caller
                .get_export("memory")
                .and_then(|e| e.into_memory())
                .expect("module has no exported memory");
            let data = memory
                .data(&mut caller)
                .get(ptr as usize..(ptr as usize + len as usize))
                .expect("host_log ptr/len out of bounds");
            let msg = String::from_utf8_lossy(data);
            println!("[host_log via wasmtime native host] {msg}");
        },
    )?;

    let mut store = Store::new(&engine, ());
    let instance = linker.instantiate(&mut store, &module)?;
    let func = instance.get_typed_func::<u32, u64>(&mut store, func_name)?;

    match func.call(&mut store, arg) {
        Ok(result) => {
            println!("{func_name}({arg}) = {result}");
        }
        Err(trap) => {
            // {:?} on wasmtime::Error prints the full error chain, which
            // includes the resolved wasm backtrace when available.
            println!("TRAP calling {func_name}({arg}):");
            println!("{trap:?}");
        }
    }
    Ok(())
}
