//! ffi_host — Rust host that provides crypto functions to AssemblyScript guest.
//!
//! Demonstrates FFI between WASM and native code for operations that benefit
//! from hardware acceleration (SHA-NI, AES-NI) or native libraries.
//!
//! Host-provided functions:
//!   - host_sha256(ptr, len) -> writes 32-byte hash to result buffer
//!   - host_get_result(dest_ptr) -> copies result to WASM memory
//!   - host_noop() -> empty function for measuring pure FFI overhead

use ring::digest::{Context, SHA256};
use std::time::Instant;
use wasmtime::*;

const WASM_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../guest/build/release.wasm"
);

/// Host state shared with WASM
struct HostState {
    /// Buffer for returning results to WASM
    result_buffer: Vec<u8>,
    /// Counter for tracking calls
    call_count: u64,
}

impl HostState {
    fn new() -> Self {
        Self {
            result_buffer: Vec::with_capacity(64),
            call_count: 0,
        }
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("--test");

    // Create wasmtime engine and module
    let engine = Engine::default();
    let module = Module::from_file(&engine, WASM_PATH).expect("Failed to load WASM module");

    // Create store with host state
    let state = HostState::new();
    let mut store = Store::new(&engine, state);

    // Create linker with host functions
    let mut linker = Linker::new(&engine);
    add_host_functions(&mut linker)?;

    // Instantiate
    let instance = linker.instantiate(&mut store, &module)?;

    match mode {
        "--test" => {
            println!("Running FFI test...\n");
            run_test(&mut store, &instance)?;
        }
        "--benchmark" => {
            let n: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(10000);
            run_benchmark(&mut store, &instance, n)?;
        }
        _ => {
            eprintln!("Usage: ffi_host [--test | --benchmark N]");
        }
    }

    Ok(())
}

fn add_host_functions(linker: &mut Linker<HostState>) -> Result<()> {
    // host_noop() - empty function for measuring pure FFI overhead
    linker.func_wrap("env", "host_noop", |_caller: Caller<'_, HostState>| {
        // Intentionally empty
    })?;

    // host_sha256(ptr, len) - compute SHA256 of data at ptr, store in result buffer
    linker.func_wrap(
        "env",
        "host_sha256",
        |mut caller: Caller<'_, HostState>, ptr: i32, len: i32| {
            let memory = caller.get_export("memory").unwrap().into_memory().unwrap();
            let data = memory.data(&caller);

            // Read input from WASM memory
            let input = &data[ptr as usize..(ptr + len) as usize];

            // Compute SHA256 using ring (with hardware acceleration)
            let mut context = Context::new(&SHA256);
            context.update(input);
            let digest = context.finish();

            // Store result
            let state = caller.data_mut();
            state.result_buffer.clear();
            state.result_buffer.extend_from_slice(digest.as_ref());
            state.call_count += 1;
        },
    )?;

    // host_get_result(dest_ptr) -> i32 (copies result to dest_ptr, returns len)
    linker.func_wrap(
        "env",
        "host_get_result",
        |mut caller: Caller<'_, HostState>, dest_ptr: i32| -> i32 {
            let data = caller.data().result_buffer.clone();
            let memory = caller.get_export("memory").unwrap().into_memory().unwrap();
            memory
                .write(&mut caller, dest_ptr as usize, &data)
                .expect("Failed to write to WASM memory");
            data.len() as i32
        },
    )?;

    // host_get_call_count() -> u64
    linker.func_wrap(
        "env",
        "host_get_call_count",
        |caller: Caller<'_, HostState>| -> i64 {
            caller.data().call_count as i64
        },
    )?;

    // AssemblyScript runtime expects abort function
    linker.func_wrap(
        "env",
        "abort",
        |_caller: Caller<'_, HostState>,
         _msg: i32,
         _file: i32,
         _line: i32,
         _col: i32| -> () {
            panic!("AssemblyScript abort called");
        },
    )?;

    Ok(())
}

fn run_test(store: &mut Store<HostState>, instance: &Instance) -> Result<()> {
    // Get exported test function
    let test_sha256 = instance
        .get_typed_func::<(), i32>(&mut *store, "test_sha256")
        .expect("test_sha256 not found");

    println!("Testing SHA256 via host FFI...");
    let result = test_sha256.call(&mut *store, ())?;

    if result == 0 {
        println!("✓ SHA256 test passed!");
    } else {
        println!("✗ SHA256 test failed with code: {}", result);
    }

    // Check call count
    let call_count = store.data().call_count;
    println!("  Host SHA256 calls: {}", call_count);

    Ok(())
}

fn run_benchmark(store: &mut Store<HostState>, instance: &Instance, n: usize) -> Result<()> {
    println!("Running {} iterations of FFI benchmarks...\n", n);

    // Benchmark 1: Pure FFI overhead (empty function)
    let bench_noop = instance
        .get_typed_func::<i32, ()>(&mut *store, "bench_noop")
        .expect("bench_noop not found");

    let t0 = Instant::now();
    bench_noop.call(&mut *store, n as i32)?;
    let noop_total = t0.elapsed();
    let noop_per_call = noop_total.as_nanos() as f64 / n as f64;

    println!("1. Pure FFI overhead (host_noop):");
    println!("   {} calls in {:?}", n, noop_total);
    println!("   {:.1} ns/call\n", noop_per_call);

    // Benchmark 2: SHA256 of small buffer (32 bytes)
    let bench_sha256_small = instance
        .get_typed_func::<i32, ()>(&mut *store, "bench_sha256_small")
        .expect("bench_sha256_small not found");

    let t0 = Instant::now();
    bench_sha256_small.call(&mut *store, n as i32)?;
    let sha_small_total = t0.elapsed();
    let sha_small_per_call = sha_small_total.as_nanos() as f64 / n as f64;

    println!("2. SHA256 (32 bytes input):");
    println!("   {} calls in {:?}", n, sha_small_total);
    println!("   {:.1} ns/call ({:.2} μs/call)\n", sha_small_per_call, sha_small_per_call / 1000.0);

    // Benchmark 3: SHA256 of larger buffer (1KB)
    let bench_sha256_1k = instance
        .get_typed_func::<i32, ()>(&mut *store, "bench_sha256_1k")
        .expect("bench_sha256_1k not found");

    let t0 = Instant::now();
    bench_sha256_1k.call(&mut *store, n as i32)?;
    let sha_1k_total = t0.elapsed();
    let sha_1k_per_call = sha_1k_total.as_nanos() as f64 / n as f64;

    println!("3. SHA256 (1KB input):");
    println!("   {} calls in {:?}", n, sha_1k_total);
    println!("   {:.1} ns/call ({:.2} μs/call)\n", sha_1k_per_call, sha_1k_per_call / 1000.0);

    // Summary
    println!("Summary:");
    println!("  FFI overhead:     {:.0} ns", noop_per_call);
    println!("  SHA256 (32B):     {:.0} ns ({:.0} ns compute)", sha_small_per_call, sha_small_per_call - noop_per_call);
    println!("  SHA256 (1KB):     {:.0} ns ({:.0} ns compute)", sha_1k_per_call, sha_1k_per_call - noop_per_call);

    Ok(())
}
