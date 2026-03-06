"""CPU-bound workload: Fibonacci + matrix multiply."""
import json
import time


def fibonacci(n):
    """Naive recursive fibonacci — intentionally slow for benchmarking."""
    if n <= 1:
        return n
    a, b = 0, 1
    for _ in range(2, n + 1):
        a, b = b, a + b
    return b


def matrix_multiply(size):
    """Multiply two NxN matrices of sequential integers."""
    a = [[i * size + j for j in range(size)] for i in range(size)]
    b = [[j * size + i for j in range(size)] for i in range(size)]
    result = [[0] * size for _ in range(size)]
    for i in range(size):
        for j in range(size):
            s = 0
            for k in range(size):
                s += a[i][k] * b[k][j]
            result[i][j] = s
    return result[0][0]  # Return top-left cell as proof of work


def handle(request_path):
    """Handle CPU-bound request. Returns JSON with timings."""
    t0 = time.time()

    fib_result = fibonacci(30)
    t_fib = time.time()

    matrix_result = matrix_multiply(20)
    t_matrix = time.time()

    return json.dumps({
        "fib_30": fib_result,
        "matrix_20x20": matrix_result,
        "timings": {
            "fib_ms": round((t_fib - t0) * 1000, 2),
            "matrix_ms": round((t_matrix - t_fib) * 1000, 2),
            "total_ms": round((t_matrix - t0) * 1000, 2),
        },
        "timestamp": time.time(),
    })
