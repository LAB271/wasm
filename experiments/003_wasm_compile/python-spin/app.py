import json
import time

from spin_sdk.http import IncomingHandler, Request, Response


class IncomingHandler(IncomingHandler):
    def handle_request(self, request: Request) -> Response:
        body = json.dumps(
            {
                "message": "Hello World",
                "timestamp": time.time(),
            }
        )
        return Response(
            200,
            {"content-type": "application/json"},
            bytes(body, "utf-8"),
        )
