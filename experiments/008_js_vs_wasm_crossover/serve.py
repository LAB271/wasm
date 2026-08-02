#!/usr/bin/env python3
"""Minimal static server for experiment 020's browser leg. Serves this
experiment's own directory (not the caller's cwd) so `output/*.wasm` and
`browser/index.html` are both reachable, with the correct .wasm mime type
(same fix experiment 010 needed — SimpleHTTPRequestHandler doesn't know
application/wasm out of the box).

Usage: python3 serve.py [port]
"""
import http.server
import os
import sys

root = os.path.dirname(os.path.abspath(__file__))


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
    }


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8020
    http.server.test(HandlerClass=Handler, port=port, bind="127.0.0.1")
