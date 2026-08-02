//! Standalone battery runner for the wasmtime leg. Compiled to wasm32-wasip1 and run
//! directly with `wasmtime run` (no JS anywhere) — this is what proves the determinism
//! result isn't an artifact of a particular JS embedding of WebAssembly, but of the
//! WASM module itself.
//!
//! Prints one CSV line per sample: `func,idx,a_hex,b_hex,result_hex`. `js/common.js`
//! prints the identical format from JS, using the identical PRNG/input formulas from
//! `rust/compute/src/lib.rs`, so `js/compare.js` can diff the two by (func, idx).

use compute::{seed_for, Xorshift32};

const N: usize = 300;
const BASE_SEED: u32 = 0xC0FFEE;

struct FnSpec {
    name: &'static str,
    arity: u8,
}

// Fixed order — this order determines each function's derived seed (see seed_for).
// Must match the FUNCTIONS array in js/common.js exactly.
const FUNCTIONS: &[FnSpec] = &[
    FnSpec { name: "add", arity: 2 },
    FnSpec { name: "sub", arity: 2 },
    FnSpec { name: "mul", arity: 2 },
    FnSpec { name: "div", arity: 2 },
    FnSpec { name: "sqrt", arity: 1 },
    FnSpec { name: "sin", arity: 1 },
    FnSpec { name: "cos", arity: 1 },
    FnSpec { name: "tan", arity: 1 },
    FnSpec { name: "pow", arity: 2 },
    FnSpec { name: "exp", arity: 1 },
    FnSpec { name: "log", arity: 1 },
];

fn hex(bits: u64) -> String {
    format!("{:016x}", bits)
}

fn call(name: &str, a: f64, b: f64) -> f64 {
    match name {
        "add" => compute::add(a, b),
        "sub" => compute::sub(a, b),
        "mul" => compute::mul(a, b),
        "div" => compute::div(a, b),
        "sqrt" => compute::sqrt(a),
        "sin" => compute::sin(a),
        "cos" => compute::cos(a),
        "tan" => compute::tan(a),
        "pow" => compute::pow(a, b),
        "exp" => compute::exp(a),
        "log" => compute::log(a),
        _ => unreachable!("unknown function {name}"),
    }
}

fn main() {
    println!("func,idx,a_hex,b_hex,result_hex");
    for (fi, spec) in FUNCTIONS.iter().enumerate() {
        let mut rng = Xorshift32::new(seed_for(BASE_SEED, fi as u32));
        for idx in 0..N {
            let a = compute::next_f64(&mut rng);
            let b = if spec.name == "pow" {
                compute::next_f64_scaled(&mut rng, 10.0)
            } else if spec.arity == 2 {
                compute::next_f64(&mut rng)
            } else {
                0.0
            };
            let result = call(spec.name, a, b);
            let b_hex = if spec.arity == 2 {
                hex(b.to_bits())
            } else {
                String::new()
            };
            println!(
                "{},{},{},{},{}",
                spec.name,
                idx,
                hex(a.to_bits()),
                b_hex,
                hex(result.to_bits())
            );
        }
    }
}
