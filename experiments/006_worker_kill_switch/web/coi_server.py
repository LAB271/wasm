#!/usr/bin/env python3
# coi_server.py — a plain static file server that adds the two headers
# SharedArrayBuffer requires (Cross-Origin-Opener-Policy /
# Cross-Origin-Embedder-Policy). Verified directly: SharedArrayBuffer is
# `undefined` in a Playwright-launched Chromium page served without these
# headers, and becomes available with them (see README).
import http.server
import os
import sys
from functools import partial


class COIHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
    # Always serve this script's own directory, regardless of the caller's
    # cwd — avoids relying on a subshell `cd` correctly propagating through
    # whatever backgrounds this process.
    web_dir = os.path.dirname(os.path.abspath(__file__))
    handler = partial(COIHandler, directory=web_dir)
    http.server.test(HandlerClass=handler, port=port, bind="127.0.0.1")
