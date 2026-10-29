"""Capture phase-2 inspection frames from the live bridge instance.

Every eval block is written at column 0 with single-line bodies because the
bridge prefixes each line with a tab (nested multi-line bodies break GDScript).
"""

import base64
import json
import socket
import sys
from pathlib import Path

TELEPORT = """
var p := get_tree().get_first_node_in_group("player")
p.teleport_to(Vector3(-5.4, 0.05, -7.6))
p.rotation.y = atan2(-(-0.4), 3.0)
if p.has_method("set_controls_enabled"): p.set_controls_enabled(true)
if p.has_method("set_mouse_captured"): p.set_mouse_captured(true)
await get_tree().create_timer(1.0).timeout
var card = get_tree().get_first_node_in_group("title_card")
if card != null and card.has_method("is_open") and card.is_open(): card.dismiss()
await get_tree().create_timer(0.8).timeout
return str(p.global_position)
"""

LOOK_AT_MILA = """
var p := get_tree().get_first_node_in_group("player")
var mila = null
for n in get_tree().get_nodes_in_group("npc"): if n.get("npc_id") == "mila": mila = n
if mila == null: return "no mila"
var target: Vector3 = mila.global_position + Vector3(0, 1.55, 0)
var cam = p.get_camera()
var flat := Vector2(target.x - p.global_position.x, target.z - p.global_position.z)
p.rotation.y = atan2(-flat.x, -flat.y)
await get_tree().create_timer(0.5).timeout
p.get_camera().look_at(target, Vector3.UP)
await get_tree().create_timer(0.4).timeout
return str(mila.global_position)
"""

RESET_CAM = """
var p := get_tree().get_first_node_in_group("player")
var cam = p.get_camera()
cam.rotation = Vector3.ZERO
await get_tree().create_timer(0.3).timeout
return str(cam.global_position)
"""


def call(command, params=None, timeout=30):
    payload = json.dumps({"command": command, "params": params or {}, "id": 1})
    with socket.create_connection(("127.0.0.1", 9090), timeout=timeout) as sock:
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
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/shots_phase2_out")
    out.mkdir(parents=True, exist_ok=True)
    print("teleport:", call("eval", {"code": TELEPORT}))
    shot(str(out / "10_spawn_phase2.png"))
    print("look:", call("eval", {"code": LOOK_AT_MILA}))
    shot(str(out / "11_mila_closeup.png"))
    print("reset:", call("eval", {"code": RESET_CAM}))
    shot(str(out / "12_camera_reset.png"))


if __name__ == "__main__":
    main()
