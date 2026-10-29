"""Diagnose why the street is pitch black away from lamps.

Dumps environment and ground material state, then adds a temporary fill light above
the player and measures the change in the lower half of the frame.
"""

import base64
import io
import json
import socket
import sys

POSITION = """
var p := get_tree().get_first_node_in_group("player")
p.teleport_to(Vector3(0.0, 0.2, 8.0))
p.rotation.y = 0.0
await get_tree().create_timer(1.0).timeout
return str(p.global_position)
"""

DUMP = """
var env := get_viewport().get_camera_3d().get_world_3d().environment
var out := "env: source=%s sky=%s bg=%s bgmode=%s energy=%s color=%s" % [str(env.ambient_light_source), str(env.ambient_light_sky_contribution), str(env.background_mode), str(env.background_energy_multiplier), str(env.ambient_light_energy), str(env.ambient_light_color)]
var ground = get_node_or_null("/root/Main/World/Ground")
if ground == null: out += " | no Ground node"
else:
\tfor child in ground.get_children(): if child is MeshInstance3D and child.mesh != null: var mat = child.mesh.surface_get_material(0); out += " | mesh=%s mat=%s" % [child.name, str(mat)]
return out
"""

FILL_ON = """
var p := get_tree().get_first_node_in_group("player")
var l := OmniLight3D.new()
l.name = "FillProbeLight"
l.light_energy = 3.0
l.omni_range = 22.0
l.shadow_enabled = false
l.position = p.global_position + Vector3(0, 6.0, 0)
p.get_parent().add_child(l)
await get_tree().create_timer(0.8).timeout
return "fill added"
"""

FILL_OFF = """
var n = get_node_or_null("/root/Main/FillProbeLight")
if n != null: n.queue_free()
await get_tree().create_timer(0.4).timeout
return "fill removed"
"""


def call(command, params=None, timeout=40):
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


def shot_bytes():
    res = call("screenshot", {}, timeout=45)
    data = res.get("data") or res.get("result", {}).get("data")
    return base64.b64decode(data) if data else None


def stats(png_bytes, label, save=None):
    from PIL import Image

    img = Image.open(io.BytesIO(png_bytes)).convert("L")
    w, h = img.size
    ground = img.crop((0, int(h * 0.6), w, h))
    px = list(ground.getdata())
    mean = sum(px) / len(px)
    bright = sum(1 for v in px if v > 25) / float(len(px))
    print(f"{label}: ground mean={mean:.1f}/255 shared>25={bright*100:.1f}%")
    if save:
        from pathlib import Path

        Path(save).parent.mkdir(parents=True, exist_ok=True)
        Path(save).write_bytes(png_bytes)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "docs/shots_light"
    print("position:", call("eval", {"code": POSITION}))
    print("dump:", call("eval", {"code": DUMP}))
    stats(shot_bytes(), "as is", f"{out}/10_asis.png")
    print("fill:", call("eval", {"code": FILL_ON}))
    stats(shot_bytes(), "with fill", f"{out}/11_fill.png")
    print("cleanup:", call("eval", {"code": FILL_OFF}))


if __name__ == "__main__":
    main()
