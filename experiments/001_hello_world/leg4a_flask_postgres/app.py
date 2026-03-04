import time

from flask import Flask, jsonify, request
from psycopg2 import pool

app = Flask(__name__)

db_pool = pool.SimpleConnectionPool(
    1, 5,
    host="127.0.0.1",
    port=5432,
    dbname="bench",
    user="bench",
    password="bench",
)


@app.route("/")
def hello():
    return jsonify({"message": "Hello World", "timestamp": time.time()})


@app.route("/db")
def db_query():
    item_id = request.args.get("id", 1, type=int)
    conn = db_pool.getconn()
    try:
        t0 = time.perf_counter()
        with conn.cursor() as cur:
            cur.execute("SELECT id, name, value FROM items WHERE id = %s", (item_id,))
            row = cur.fetchone()
        query_ms = (time.perf_counter() - t0) * 1000
    finally:
        db_pool.putconn(conn)

    if row is None:
        return jsonify({"error": "not found"}), 404

    return jsonify({
        "id": row[0],
        "name": row[1],
        "value": row[2],
        "query_ms": round(query_ms, 3),
        "timestamp": time.time(),
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5004)
