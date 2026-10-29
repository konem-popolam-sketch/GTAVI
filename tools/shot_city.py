"""City overview frames for t32 (free camera, no player teleport)."""

import base64
import json
import socket
import sys
from pathlib import Path

PORT = 9090

CAM = """
var old = get_tree().current_scene.get_node_or_null("CityCam")
if old != null: old.queue_free()
var cam = Camera3D.new()
cam.name = "CityCam"
cam.fov = {fov}
cam.far = 900.0
cam.position = Vector3({px}, {py}, {pz})
get_tree().current_scene.add_child(cam)
cam.look_at(Vector3({tx}, {ty}, {tz}))
cam.current = true
await get_tree().create_timer(1.0).timeout
return "ok"
"""

DROP = """
var cam = get_tree().current_scene.get_node_or_null("CityCam")
if cam != null: cam.queue_free()
return "removed"
"""

VIEWS = [
    ("01_aerial", dict(fov="55.0", px="-90", py="120", pz="60", tx="0", ty="0", tz="-220")),
    ("02_street", dict(fov="60.0", px="-113", py="2.2", pz="-70", tx="-113", ty="1.4", tz="-250")),
    ("03_club", dict(fov="60.0", px="26", py="3.2", pz="-32", tx="0", ty="5", tz="-72")),
]


def call(command, params=None, timeout=60):
    payload = json.dumps({"command": command, "params": params or {}, "id": 1})
    with socket.create_connection(("127.0.0.1", PORT), timeout=timeout) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode())


def eval_code(code):
    res = call("eval", {"code": code})
    return res.get("result", res)


def shot(path):
    res = call("screenshot", {}, timeout=60)
    data = res.get("data") or res.get("result", {}).get("data")
    if not data:
        print("  no data", res)
        return
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(base64.b64decode(data))
    print("  saved", target)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/shots_t32")
    for name, view in VIEWS:
        print(f"[{name}]", eval_code(CAM.format(**view)))
        shot(out / f"{name}.png")
    print("  ", eval_code(DROP))


if __name__ == "__main__":
    main()
