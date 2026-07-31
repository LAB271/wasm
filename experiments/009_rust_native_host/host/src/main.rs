// wasm_host — a native Rust process that embeds `wasmtime` as a library,
// not a CLI subprocess and not an HTTP server. This is the missing fourth
// architecture in this repo: experiments 004-008 host WASM in a browser
// Worker; 001/003 treat `wasmtime serve`/`spin up` as a black-box HTTP
// server. Nothing until now has measured a direct, in-process function
// call with no network layer between the caller and the WASM instance —
// which is exactly what the article this experiment responds to actually
// benchmarked, and exactly the number its own methodology doesn't fully
// justify (see README).
//
// Two modes:
//   --single-shot   Full init -> compile -> instantiate -> call -> exit,
//                    once. Meant to be wrapped by an external wall-clock
//                    timer (the benchmark script), so "cold start" means
//                    what it should: everything, including process launch,
//                    not just a warm loop inside an already-running process.
//   --loop N        Compile once, then N iterations of fresh Store +
//                    Instance + call + drop, each timed individually.
//                    This is the article's own methodology, reproduced
//                    faithfully so its number is directly checkable rather
//                    than taken on faith -- with the first iteration
//                    reported separately from the rest, since bundling it
//                    into one average is exactly the thing that made the
//                    article's number read as "cold" when it wasn't.
use std::env;
use std::time::Instant;
use wasmtime::{Engine, Instance, Module, Store};

const WASM_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../guest/target/wasm32-unknown-unknown/release/transform_guest.wasm");

fn call_transform(engine: &Engine, module: &Module, input: i64) -> i64 {
    let mut store = Store::new(engine, ());
    let instance = Instance::new(&mut store, module, &[]).expect("instantiate");
    let func = instance
        .get_typed_func::<i64, i64>(&mut store, "transform")
        .expect("get transform");
    func.call(&mut store, input).expect("call transform")
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("--single-shot");

    if mode == "--single-shot" {
        let t0 = Instant::now();
        let engine = Engine::default();
        let module = Module::from_file(&engine, WASM_PATH).expect("compile module");
        let result = call_transform(&engine, &module, 10000);
        let elapsed = t0.elapsed();
        // Everything: engine init, first-ever module compile, instantiate,
        // call. This is the number "cold start" should mean.
        println!("single-shot: result={result} elapsed_us={}", elapsed.as_micros());
        return;
    }

    // --loop N
    let n: usize = args
        .get(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(1000);

    let engine = Engine::default();
    let module = Module::from_file(&engine, WASM_PATH).expect("compile module");

    let mut times_us: Vec<u128> = Vec::with_capacity(n);
    for _ in 0..n {
        let t0 = Instant::now();
        let _ = call_transform(&engine, &module, 10000);
        times_us.push(t0.elapsed().as_micros());
    }

    let first = times_us[0];
    let rest = &times_us[1..];
    let mut sorted_rest = rest.to_vec();
    sorted_rest.sort_unstable();
    let median = sorted_rest[sorted_rest.len() / 2];
    let min = *sorted_rest.first().unwrap();
    let max = *sorted_rest.last().unwrap();
    let sum: u128 = sorted_rest.iter().sum();
    let avg = sum / sorted_rest.len() as u128;

    println!("loop: n={n}");
    println!("  first iteration (includes any first-call JIT lag): {first}us");
    println!("  remaining {} iterations: min={min}us median={median}us avg={avg}us max={max}us", sorted_rest.len());
}
