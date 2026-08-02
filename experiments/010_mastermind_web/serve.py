#!/usr/bin/env python3
"""serve.py — small static server for the mastermind_web experiment.

Serves web/ (index.html, style.css, dist/app.js, mvl-runtime.js, code.wasm).
No COOP/COEP headers needed here (unlike experiment 006) — this experiment
doesn't use SharedArrayBuffer/Atomics, just a plain fetch() of a .wasm file
and WebAssembly.instantiate(), both same-origin.

Supports HTTP compression:
  - Serves pre-compressed .br (brotli) or .gz (gzip) sidecars, built at
    `make build` time, for every COMPRESSIBLE_EXTS extension (.wasm, .js —
    the wasm engines, web/dist/*.js, and the base64-inlined engine-*.b64.js)
  - Compresses JSON API responses with gzip at request time (the one thing
    here that isn't a static file, so it can't be pre-compressed)

CORS: sends Access-Control-Allow-Origin (+ Methods/Headers) on every response
and answers OPTIONS preflight, so a page on one instance can fetch() a .wasm
served by another (see web/inline.html's cross-origin demo). Pass --no-cors
to omit those headers and demonstrate the blocked case instead — this is
precisely the failure the base64-inline loading strategy sidesteps, since the
inlined module rides along as part of the page's own same-origin JS and never
issues that cross-origin request in the first place.

Repeats the exp004/006 lesson learned the hard way earlier in this repo's
history: serve from THIS script's own directory, not the caller's cwd —
`os.path.dirname(os.path.abspath(__file__))` regardless of where the script
was invoked from.

API endpoints for CLI play:
  POST /api/new    -> {"game_id": "...", "message": "..."}
  POST /api/guess  -> {"guess": [1,2,3,4]} -> {"blacks": N, "whites": N, "won": bool, "attempts": N}

Usage:
  python3 serve.py [port] [--no-cors]
"""
import gzip
import http.server
import json
import os
import random
import sys
from urllib.parse import urlparse

web_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")

# Set from argv in __main__ (module-level so Handler methods can read it).
cors_enabled = True

# Game state (single game for simplicity)
current_game = {"secret": None, "attempts": 0, "max_attempts": 10}

COLOR_NAMES = ["Red", "Green", "Blue", "Yellow", "Orange", "Purple"]


def score_guess(secret: list[int], guess: list[int]) -> tuple[int, int]:
    """Score a guess: returns (blacks, whites)."""
    blacks = sum(s == g for s, g in zip(secret, guess))
    # Count color matches (not position)
    secret_counts = [0] * 6
    guess_counts = [0] * 6
    for s, g in zip(secret, guess):
        if s != g:
            secret_counts[s - 1] += 1
            guess_counts[g - 1] += 1
    whites = sum(min(secret_counts[i], guess_counts[i]) for i in range(6))
    return blacks, whites


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=web_dir, **kwargs)

    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
    }

    # Extensions pre-compressed at build time (Makefile: build-rust/build-as
    # gzip+brotli the .wasm engines, build-ui does web/dist/*.js, build-inline
    # does engine-*.b64.js) — .wasm and .js share the do_GET path below, with
    # Content-Type looked up from extensions_map rather than hardcoded.
    COMPRESSIBLE_EXTS = (".wasm", ".js")

    def end_headers(self):
        """Single choke point for every response path (do_GET's default
        handling, _serve_compressed, and the JSON API) — add CORS headers
        here rather than duplicating them at each send_response call site."""
        if cors_enabled:
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
        super().end_headers()

    def do_OPTIONS(self):
        """Answer CORS preflight requests (browsers send these ahead of
        cross-origin POSTs with a JSON content-type, among other cases)."""
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        """Serve pre-compressed .br/.gz sidecars for COMPRESSIBLE_EXTS files
        when one exists and the client accepts that encoding."""
        path = urlparse(self.path).path
        ext = os.path.splitext(path)[1]
        if ext in self.COMPRESSIBLE_EXTS:
            accept_encoding = self.headers.get("Accept-Encoding", "")
            file_path = os.path.join(web_dir, path.lstrip("/"))
            content_type = self.extensions_map[ext]

            # Try brotli first (better compression)
            if "br" in accept_encoding and os.path.exists(file_path + ".br"):
                self._serve_compressed(file_path + ".br", content_type, "br")
                return
            # Fall back to gzip
            if "gzip" in accept_encoding and os.path.exists(file_path + ".gz"):
                self._serve_compressed(file_path + ".gz", content_type, "gzip")
                return

        # Default behavior for other files
        super().do_GET()

    def _serve_compressed(self, file_path: str, content_type: str, encoding: str):
        """Serve a pre-compressed file with appropriate headers."""
        try:
            with open(file_path, "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Encoding", encoding)
            self.send_header("Content-Length", len(data))
            self.send_header("Vary", "Accept-Encoding")
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_error(500, str(e))

    def do_POST(self):
        path = urlparse(self.path).path

        if path == "/api/new":
            current_game["secret"] = [random.randint(1, 6) for _ in range(4)]
            current_game["attempts"] = 0
            self._json_response({
                "message": "New game started. Guess a code of 4 colors (1-6: R,G,B,Y,O,P).",
                "colors": {i + 1: name for i, name in enumerate(COLOR_NAMES)},
                "max_attempts": current_game["max_attempts"],
            })

        elif path == "/api/guess":
            if current_game["secret"] is None:
                self._json_response({"error": "No game in progress. POST /api/new first."}, 400)
                return

            content_len = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_len)
            try:
                data = json.loads(body)
                guess = data.get("guess", [])
            except json.JSONDecodeError:
                self._json_response({"error": "Invalid JSON"}, 400)
                return

            if len(guess) != 4 or not all(isinstance(g, int) and 1 <= g <= 6 for g in guess):
                self._json_response({"error": "Guess must be 4 integers 1-6"}, 400)
                return

            current_game["attempts"] += 1
            blacks, whites = score_guess(current_game["secret"], guess)
            won = blacks == 4
            lost = current_game["attempts"] >= current_game["max_attempts"] and not won

            response = {
                "guess": guess,
                "guess_colors": [COLOR_NAMES[g - 1] for g in guess],
                "blacks": blacks,
                "whites": whites,
                "attempts": current_game["attempts"],
                "won": won,
                "lost": lost,
            }

            if won:
                response["message"] = f"You cracked it in {current_game['attempts']} guesses!"
                current_game["secret"] = None
            elif lost:
                response["message"] = f"Out of attempts! The secret was {[COLOR_NAMES[s-1] for s in current_game['secret']]}"
                current_game["secret"] = None

            self._json_response(response)

        else:
            self._json_response({"error": "Not found"}, 404)

    def _json_response(self, data: dict, status: int = 200):
        body = json.dumps(data).encode()
        accept_encoding = self.headers.get("Accept-Encoding", "")

        self.send_response(status)
        self.send_header("Content-Type", "application/json")

        # Compress JSON responses if client accepts gzip
        if "gzip" in accept_encoding and len(body) > 100:
            body = gzip.compress(body)
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")

        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    args = sys.argv[1:]
    cors_enabled = "--no-cors" not in args
    port_args = [a for a in args if a != "--no-cors"]
    port = int(port_args[0]) if port_args else 8010
    http.server.test(HandlerClass=Handler, port=port, bind="127.0.0.1")
