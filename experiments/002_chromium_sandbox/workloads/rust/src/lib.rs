// CPU-bound workload: Fibonacci + matrix multiply — Rust/WASM equivalent
// of workloads/cpu_bound.py, for comparing native-WASM cold start/throughput
// against Pyodide (Python-in-WASM) in the same Chromium harness.
use wasm_bindgen::prelude::*;

fn fibonacci(n: u32) -> u64 {
    if n <= 1 {
        return n as u64;
    }
    let (mut a, mut b) = (0u64, 1u64);
    for _ in 2..=n {
        let next = a + b;
        a = b;
        b = next;
    }
    b
}

fn matrix_multiply(size: usize) -> i64 {
    let a: Vec<Vec<i64>> = (0..size)
        .map(|i| (0..size).map(|j| (i * size + j) as i64).collect())
        .collect();
    let b: Vec<Vec<i64>> = (0..size)
        .map(|i| (0..size).map(|j| (j * size + i) as i64).collect())
        .collect();
    let mut result = vec![vec![0i64; size]; size];
    for i in 0..size {
        for j in 0..size {
            let mut s = 0i64;
            for k in 0..size {
                s += a[i][k] * b[k][j];
            }
            result[i][j] = s;
        }
    }
    result[0][0]
}

#[wasm_bindgen]
pub fn handle() -> String {
    let fib_result = fibonacci(30);
    let matrix_result = matrix_multiply(20);

    format!(
        "{{\"fib_30\":{},\"matrix_20x20\":{}}}",
        fib_result, matrix_result
    )
}
