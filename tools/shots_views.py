"""Capture balanced art frames (spawn, shop, pier) from the live bridge.

Camera pitch is left alone on purpose: forcing look_at tilted the probe camera and
made frames unrepresentative. Only position and yaw are set.
"""

import base64
import json
import socket
import sys
from pathlib import Path

VIEWS = [
    ("20_spawn.png", (0.0, 0.2, 8.0), 0.0),
    ("21_shop.png", (-4.6, 0.05, -7.4), 0.45),
    ("22_pier.png", (0.0, -0.6, 29.0), 3.14159),
]

MOVE = """
var p := get_tree().get_first_node_in_group("player")
var card = get_tree().get_first_node_in_group("title_card")
if card == null: card = get_node_or_null("/root/Main/UI/TitleCard")
if card != null and card.has_method("dismiss"): card.dismiss()
await get_tree().create_timer(0.9).timeout
p.teleport_to(Vector3({x}, {y}, {z}))
p.rotation.y = {yaw}
if p.has_method("set_controls_enabled"): p.set_controls_enabled(true)
await get_tree().create_timer(1.4).timeout
return str(p.global_position)
"""


def port():
    import os

    return int(os.environ.get("GODOT_BRIDGE_PORT", "9090"))


def call(command, params=None, timeout=30):
    payload = json.dumps({"command": command, "params": params or {}, "id": 1})
    with socket.create_connection(("127.0.0.1", port()), timeout=timeout) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode())


def shot(path):
    res = call("screenshot", {}, timeout=45)
    data = res.get("data") or res.get("result", {}).get("data")
    if not data:
        print("no screenshot data", res)
        return
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(base64.b64decode(data))
    print("saved", path)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/shots_art2")
    out.mkdir(parents=True, exist_ok=True)
    for name, (x, y, z), yaw in VIEWS:
        code = MOVE.format(x=x, y=y, z=z, yaw=yaw)
        print(name, call("eval", {"code": code}))
        shot(str(out / name))


if __name__ == "__main__":
    main()
