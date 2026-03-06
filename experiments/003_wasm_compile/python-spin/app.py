import json
import time

from spin_sdk import http
from spin_sdk.http import Request, Response


def handle_request(request: Request) -> Response:
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
