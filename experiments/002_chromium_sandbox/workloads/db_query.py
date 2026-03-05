"""DB query workload: format pre-fetched database row."""
import json
import time


def handle(request_path, row):
    """Handle DB query request.

    The row is pre-fetched by the Node.js host (bridge pattern).
    row = [id, name, value, query_ms] or None if not found.
    """
    t0 = time.time()

    if row is None:
        return json.dumps({"error": "not found"})

    result = {
        "id": row[0],
        "name": row[1],
        "value": row[2],
        "query_ms": row[3],
        "computed": row[2] * 2.5,  # Derived field to prove WASM did work
        "format_ms": 0,
        "timestamp": time.time(),
    }

    t1 = time.time()
    result["format_ms"] = round((t1 - t0) * 1000, 2)

    return json.dumps(result)
