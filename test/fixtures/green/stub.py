"""The application under test, for fixture generation only.

Not run in CI: the workflow compares a stored run and never calls a target.
This exists so `regenerate.sh` can produce those stored runs deterministically,
and so a reader can see what answered.

    python3 stub.py           # the answers the baseline was approved on
    WORSE=1 python3 stub.py   # one answer degraded, which is the red fixture
"""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8731

FINE = {
    "Where is order 4821?": "Order 4821 is due Thursday. — Acme Support",
    "How do I send it back?": "Print a label from your order page. — Acme Support",
}

#: One answer loses the sign-off, so `contains` flips from pass to fail. A flip
#: is never rescued by a tolerance, which is what makes the red fixture stable.
WORSE = {**FINE, "Where is order 4821?": "Order 4821 is due Thursday."}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802 - the name http.server dispatches on
        length = int(self.headers.get("Content-Length") or 0)
        asked = json.loads(self.rfile.read(length).decode("utf-8"))
        answers = WORSE if os.environ.get("WORSE") else FINE
        body = json.dumps(
            {
                "data": {"answer": answers.get(str(asked.get("question", "")), "?")},
                "usage": {"cost_usd": 0.0001, "elapsed_ms": 12.0},
                "config": {"provider": "openai", "model": "gpt-4o-mini"},
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self) -> None:  # noqa: N802 - the name http.server dispatches on
        self.send_response(200)
        self.end_headers()

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Quiet."""


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
