#!/usr/bin/env python3
"""serve.py — small static server for the mastermind_web experiment.

Serves web/ (index.html, style.css, dist/app.js, mvl-runtime.js, code.wasm).
No COOP/COEP headers needed here (unlike experiment 006) — this experiment
doesn't use SharedArrayBuffer/Atomics, just a plain fetch() of a .wasm file
and WebAssembly.instantiate(), both same-origin.

Repeats the exp004/006 lesson learned the hard way earlier in this repo's
history: serve from THIS script's own directory, not the caller's cwd —
`os.path.dirname(os.path.abspath(__file__))` regardless of where the script
was invoked from.

API endpoints for CLI play:
  POST /api/new    -> {"game_id": "...", "message": "..."}
  POST /api/guess  -> {"guess": [1,2,3,4]} -> {"blacks": N, "whites": N, "won": bool, "attempts": N}
"""
import http.server
import json
import os
import random
import sys
from urllib.parse import urlparse

web_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")

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
    }

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
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8010
    http.server.test(HandlerClass=Handler, port=port, bind="127.0.0.1")
