"""The application under test, for fixture generation only.

The action's jobs compare a stored run and never call a target. This exists
so `regenerate.sh` can produce those stored runs deterministically, and so a
reader can see what answered. `test/stub.sh` runs it in CI, to hold the line
it writes for every call it receives.

    python3 stub.py           # the answers the baseline was approved on
    WORSE=1 python3 stub.py   # one answer degraded, which is the red fixture
"""

from __future__ import annotations

import itertools
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

#: 8731, because `suite.toml` names it. `STUB_PORT` moves it, for
#: `test/stub.sh`, which runs a copy with the port rewritten in that copy.
PORT = int(os.environ.get("STUB_PORT", "8731"))

FINE = {
    "Where is order 4821?": "Order 4821 is due Thursday. — Acme Support",
    "How do I send it back?": "Print a label from your order page. — Acme Support",
}

#: One answer loses the sign-off, so `contains` flips from pass to fail. A flip
#: is never rescued by a tolerance, which is what makes the red fixture stable.
WORSE = {**FINE, "Where is order 4821?": "Order 4821 is due Thursday."}


#: The second witness. One line on standard error for every call this stub
#: receives, and nothing when it receives none, so a sentence such as
#: "Nothing was called" can be checked against more than digline's word. The
#: format of digline's example stubs; the liveness `HEAD` is not a call.
_CALLS = itertools.count(1)
_COUNTING = threading.Lock()


def _witness(path: str, field: str, value: str) -> None:
    with _COUNTING:
        number = next(_CALLS)
    sys.stderr.write(f"stub: call {number} POST {path} {field}={value!r}\n")
    sys.stderr.flush()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802 - the name http.server dispatches on
        length = int(self.headers.get("Content-Length") or 0)
        asked = json.loads(self.rfile.read(length).decode("utf-8"))
        _witness(self.path, "question", str(asked.get("question", "")))
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
        """`http.server`'s own access log stays off: `_witness` writes the
        one line per call."""


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
