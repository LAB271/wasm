"""JSON transform workload: parse, transform, serialize."""
import json
import time


def generate_input(n_items=50):
    """Generate a list of items to transform (~1KB input)."""
    return [{"id": i, "name": f"item_{i}", "value": i * 3.14, "active": i % 2 == 0}
            for i in range(n_items)]


def transform(items):
    """Transform items: filter active, compute derived fields, sort."""
    result = []
    for item in items:
        if item["active"]:
            result.append({
                "id": item["id"],
                "label": item["name"].upper(),
                "score": round(item["value"] * 2.5, 2),
                "tier": "gold" if item["value"] > 100 else "silver" if item["value"] > 50 else "bronze",
            })
    result.sort(key=lambda x: x["score"], reverse=True)
    return result


def handle(request_path):
    """Handle JSON transform request. Returns JSON with timings."""
    t0 = time.time()

    # Parse phase (simulate receiving JSON input)
    raw_input = json.dumps(generate_input(50))
    t_gen = time.time()

    items = json.loads(raw_input)
    t_parse = time.time()

    # Transform phase
    transformed = transform(items)
    t_transform = time.time()

    # Serialize phase
    output = json.dumps(transformed)
    t_serialize = time.time()

    return json.dumps({
        "input_size": len(raw_input),
        "output_size": len(output),
        "items_in": len(items),
        "items_out": len(transformed),
        "timings": {
            "generate_ms": round((t_gen - t0) * 1000, 2),
            "parse_ms": round((t_parse - t_gen) * 1000, 2),
            "transform_ms": round((t_transform - t_parse) * 1000, 2),
            "serialize_ms": round((t_serialize - t_transform) * 1000, 2),
            "total_ms": round((t_serialize - t0) * 1000, 2),
        },
        "timestamp": time.time(),
    })
