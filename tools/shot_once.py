"""Take one screenshot from a bridge instance on a chosen port.

Usage: python tools/shot_once.py <port> <out-png>
"""

import base64
import json
import socket
import sys
from pathlib import Path


def call(port, command, params=None, timeout=40):
    payload = json.dumps({"command": command, "params": params or {}, "id": 1})
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode())


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9090
    out = sys.argv[2] if len(sys.argv) > 2 else "docs/probe_shot.png"
    res = call(port, "screenshot")
    data = res.get("data") or res.get("result", {}).get("data")
    if not data:
        print("no data", res)
        return
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_bytes(base64.b64decode(data))
    print("saved", out)


if __name__ == "__main__":
    main()
