// CPU-bound workload: Fibonacci + matrix multiply — AssemblyScript/WASM
// equivalent of workloads/cpu_bound.py, for comparing native-WASM cold
// start/throughput against Pyodide (Python-in-WASM) in the same Chromium harness.

function fibonacci(n: i32): u64 {
  if (n <= 1) return n as u64;
  let a: u64 = 0;
  let b: u64 = 1;
  for (let i = 2; i <= n; i++) {
    const next = a + b;
    a = b;
    b = next;
  }
  return b;
}

function matrixMultiply(size: i32): i64 {
  const a = new Array<Array<i64>>(size);
  const b = new Array<Array<i64>>(size);
  for (let i = 0; i < size; i++) {
    a[i] = new Array<i64>(size);
    b[i] = new Array<i64>(size);
    for (let j = 0; j < size; j++) {
      a[i][j] = (i * size + j) as i64;
      b[i][j] = (j * size + i) as i64;
    }
  }
  const result = new Array<Array<i64>>(size);
  for (let i = 0; i < size; i++) {
    result[i] = new Array<i64>(size);
    for (let j = 0; j < size; j++) {
      let s: i64 = 0;
      for (let k = 0; k < size; k++) {
        s += a[i][k] * b[k][j];
      }
      result[i][j] = s;
    }
  }
  return result[0][0];
}

export function handle(): string {
  const fibResult = fibonacci(30);
  const matrixResult = matrixMultiply(20);
  return '{"fib_30":' + fibResult.toString() + ',"matrix_20x20":' + matrixResult.toString() + "}";
}
