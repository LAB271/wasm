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
"""
import http.server
import os
import sys

web_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=web_dir, **kwargs)

    # .wasm must be served with the right MIME type for
    # WebAssembly.instantiateStreaming; SimpleHTTPRequestHandler's default
    # mimetypes map already has this on modern Python, but pin it
    # explicitly rather than trust the host's system mimetypes.
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
    }


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8010
    http.server.test(HandlerClass=Handler, port=port, bind="127.0.0.1")
