"""Mixed workload: CPU + JSON transform + DB formatting."""
import json
import time


def fibonacci(n):
    """Iterative fibonacci."""
    if n <= 1:
        return n
    a, b = 0, 1
    for _ in range(2, n + 1):
        a, b = b, a + b
    return b


def transform_items(items):
    """Transform a list of items."""
    return [{"id": it["id"], "label": it["name"].upper(), "score": round(it["value"] * 2.5, 2)}
            for it in items if it.get("active", False)]


def handle(request_path, db_row=None):
    """Handle mixed workload request.

    Combines CPU work, JSON transform, and DB row formatting.
    db_row = [id, name, value, query_ms] or None.
    """
    t0 = time.time()

    # CPU phase
    fib_result = fibonacci(25)
    t_cpu = time.time()

    # JSON phase
    items = [{"id": i, "name": f"item_{i}", "value": i * 3.14, "active": i % 2 == 0}
             for i in range(30)]
    transformed = transform_items(items)
    json_output = json.dumps(transformed)
    t_json = time.time()

    # DB format phase
    db_info = None
    if db_row is not None:
        db_info = {"id": db_row[0], "name": db_row[1], "value": db_row[2], "query_ms": db_row[3]}
    t_db = time.time()

    return json.dumps({
        "fib_25": fib_result,
        "json_items": len(transformed),
        "json_size": len(json_output),
        "db": db_info,
        "timings": {
            "cpu_ms": round((t_cpu - t0) * 1000, 2),
            "json_ms": round((t_json - t_cpu) * 1000, 2),
            "db_format_ms": round((t_db - t_json) * 1000, 2),
            "total_ms": round((t_db - t0) * 1000, 2),
        },
        "timestamp": time.time(),
    })
