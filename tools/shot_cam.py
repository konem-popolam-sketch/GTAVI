"""Free-camera frames: `python tools/shot_cam.py docs/out name px,py,pz tx,ty,tz [fov] ...`

One or more views; a temporary Camera3D is created, aimed and removed afterwards, so the
player is never teleported (teleport is pushed out of collisions, see docs/art/README.md §9).
"""

import base64
import json
import socket
import sys
from pathlib import Path

PORT = 9090

CAM = """
var old = get_tree().current_scene.get_node_or_null("ProbeCam")
if old != null: old.queue_free()
var cam = Camera3D.new()
cam.name = "ProbeCam"
cam.fov = {fov}
cam.far = 1200.0
cam.position = Vector3({px}, {py}, {pz})
get_tree().current_scene.add_child(cam)
cam.look_at(Vector3({tx}, {ty}, {tz}))
cam.current = true
await get_tree().create_timer(1.0).timeout
return "ok"
"""

DROP = """
var cam = get_tree().current_scene.get_node_or_null("ProbeCam")
if cam != null: cam.queue_free()
return "removed"
"""

# Title card owns a 0.88 dim layer; probes must dismiss it by node path (it is not in the
# "title_card" group — see docs/probe notes), and pause menu must be closed.
SETTLE = """
var ui = get_tree().current_scene.get_node_or_null("UI")
var card = ui.get_node_or_null("TitleCard") if ui != null else null
if card != null and card.has_method("dismiss"): card.dismiss()
var pm = ui.get_node_or_null("PauseMenu") if ui != null else null
if pm != null and pm.has_method("close"): pm.close()
get_tree().paused = false
await get_tree().create_timer(0.9).timeout
return "settled"
"""


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


def parse_view(spec):
    name, pos, look = spec.split(":")
    px, py, pz = (float(v) for v in pos.split(","))
    tx, ty, tz = (float(v) for v in look.split(","))
    return name, dict(fov="65.0", px=px, py=py, pz=pz, tx=tx, ty=ty, tz=tz)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return
    out = Path(sys.argv[1])
    print("[settle]", eval_code(SETTLE))
    for spec in sys.argv[2:]:
        name, view = parse_view(spec)
        print(f"[{name}]", eval_code(CAM.format(**view)))
        shot(out / f"{name}.png")
    print("  ", eval_code(DROP))


if __name__ == "__main__":
    main()
