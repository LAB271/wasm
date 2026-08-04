#!/usr/bin/env python3
"""Determine whether an HTTP server handles connections sequentially or concurrently.

Purely a client-side probe — the server needs no instrumentation, no special
endpoint, and no cooperation. That matters here because leg A is a WASM guest
that owns its own socket and cannot be made to report on itself.

Method — head-of-line blocking:

  1. Client A connects and sends NOTHING, holding the connection open.
  2. Client B connects and sends a complete, valid request.
  3. If B gets a response while A is still idle, the server is CONCURRENT.
     If B gets nothing, the server is SEQUENTIAL: it accepted A, blocked in
     read() waiting for bytes that never come, and never reached accept() again.
  4. Close A, then retry B. A sequential server must now answer, which
     distinguishes "blocked behind A" from "broken / not listening".

Step 4 is what makes this a real test rather than a timeout: without it, a dead
server and a serialised server look identical.

Exit 0 and print the verdict; exit 2 if the server never answers even after A
is released (i.e. the probe could not reach a working server at all).
"""
import socket
import sys
import time

HOST = "127.0.0.1"
REQUEST = b"GET /health HTTP/1.1\r\nHost: probe\r\nConnection: close\r\n\r\n"
BLOCK_WAIT = 2.0  # how long B waits while A holds the server
FREED_WAIT = 5.0  # how long B waits after A is released


def try_request(port, timeout):
    """Send a full request on a fresh connection. Return (elapsed, response|None)."""
    start = time.monotonic()
    try:
        with socket.create_connection((HOST, port), timeout=timeout) as s:
            s.sendall(REQUEST)
            s.settimeout(timeout)
            data = s.recv(256)
            return time.monotonic() - start, data or None
    except (socket.timeout, TimeoutError):
        return time.monotonic() - start, None
    except OSError as e:
        print(f"  connect error: {e}", file=sys.stderr)
        return time.monotonic() - start, None


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

    # Sanity: the server must answer a lone request before we conclude anything
    # from silence. Otherwise "sequential" and "down" are indistinguishable.
    elapsed, baseline = try_request(port, FREED_WAIT)
    if baseline is None:
        print(f"UNREACHABLE  no response to a lone request on :{port} after {elapsed:.1f}s")
        return 2
    print(f"  baseline: lone request answered in {elapsed * 1000:.0f}ms")

    # 1. Client A: connect, send nothing, hold the connection.
    hog = socket.create_connection((HOST, port), timeout=FREED_WAIT)
    try:
        time.sleep(0.3)  # let the server accept A and block in read()

        # 2/3. Client B, while A is held.
        elapsed, resp = try_request(port, BLOCK_WAIT)
        if resp is not None:
            print(f"CONCURRENT   second client answered in {elapsed * 1000:.0f}ms "
                  f"while the first was held open")
            return 0
        print(f"  blocked: second client got nothing in {BLOCK_WAIT:.0f}s "
              f"while the first was held open")
    finally:
        # 4. Release A.
        hog.close()

    elapsed, resp = try_request(port, FREED_WAIT)
    if resp is None:
        print(f"UNREACHABLE  no response even after releasing the first client "
              f"({elapsed:.1f}s) — server may have died, not merely serialised")
        return 2

    print(f"SEQUENTIAL   second client answered in {elapsed * 1000:.0f}ms only "
          f"after the first was released")
    return 0


if __name__ == "__main__":
    sys.exit(main())
