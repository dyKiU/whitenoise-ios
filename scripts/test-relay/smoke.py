#!/usr/bin/env python3
"""Check an empty Nostr query through the local relay or its SSH tunnel."""
import argparse
import base64
import hashlib
import json
import os
import socket
import struct

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=18181)
args = parser.parse_args()


def read_exact(connection, size):
    result = b""
    while len(result) < size:
        chunk = connection.recv(size - len(result))
        if not chunk:
            raise RuntimeError("Relay closed before completing the response")
        result += chunk
    return result


with socket.create_connection(("127.0.0.1", args.port), timeout=5) as connection:
    key = base64.b64encode(os.urandom(16)).decode()
    request = (
        f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{args.port}\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    )
    connection.sendall(request.encode())
    header = b""
    while not header.endswith(b"\r\n\r\n"):
        if len(header) >= 65536:
            raise RuntimeError("Oversized handshake")
        header += read_exact(connection, 1)
    expected = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
    )
    assert header.startswith(b"HTTP/1.1 101 "), "WebSocket upgrade failed"
    assert expected in header, "Incorrect WebSocket accept key"
    payload = json.dumps(["REQ", "sync-smoke", {"kinds": [1], "limit": 1}]).encode()
    assert len(payload) < 126
    mask = os.urandom(4)
    connection.sendall(
        bytes([0x81, 0x80 | len(payload)]) + mask
        + bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    )
    first, second = read_exact(connection, 2)
    assert first == 0x81 and not second & 0x80, "Unexpected relay response frame"
    size = second & 0x7F
    if size == 126:
        size = struct.unpack("!H", read_exact(connection, 2))[0]
    assert size < 65536, "Unexpected response size"
    assert json.loads(read_exact(connection, size)) == ["EOSE", "sync-smoke"], "Empty-query response failed"
print("PASS: WebSocket upgrade and empty Nostr query through loopback")
