"""A/B evidence frames for the t35 metal-spark fix, shot with a free camera.

Player teleport snaps into collision, so vantage points are set by a temporary
Camera3D ("ABcam") that looks straight at each rail mesh; both frames use the
identical camera, so the only difference is the rail material.
Bridge constraint: every eval line gets one TAB prefix, so code stays flat
(`if cond: stmt` on a single line, no indented blocks).
"""

import base64
import json
import socket
import sys
from pathlib import Path

PORT = 9090

COLLECT = """
var out = []
for n in get_tree().current_scene.find_children("*", "MeshInstance3D", true, false): if "Rail" in String(n.name): out.append("%s|%s|%.2f,%.2f,%.2f" % [str(n.get_path()), String(n.name), n.global_position.x, n.global_position.y, n.global_position.z])
return out
"""

MAKE_CAM = """
var old = get_tree().current_scene.get_node_or_null("ABcam")
if old != null: old.queue_free()
var cam = Camera3D.new()
cam.name = "ABcam"
cam.fov = 40.0
cam.position = Vector3({px}, {py}, {pz})
get_tree().current_scene.add_child(cam)
cam.look_at(Vector3({tx}, {ty}, {tz}))
cam.current = true
await get_tree().create_timer(0.7).timeout
return "cam at %s -> %s" % [str(cam.global_position), str(Vector3({tx}, {ty}, {tz}))]
"""

SET_MAT = """
var mat = load("{path}")
if mat == null: return "no material"
var touched = 0
for p in {paths}: if get_node_or_null(p) != null: get_node(p).material_override = mat
for p in {paths}: if get_node_or_null(p) != null: touched += 1
return "touched=%d" % touched
"""

DROP_CAM = """
var cam = get_tree().current_scene.get_node_or_null("ABcam")
if cam != null: cam.queue_free()
return "cam removed"
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
        print("  no screenshot data", res)
        return None
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(base64.b64decode(data))
    print(f"  saved {target.name}")
    return target


def white_count(path):
    try:
        from PIL import Image
    except ImportError:
        return None
    img = Image.open(path).convert("RGB")
    w, h = img.size
    px = img.load()
    whites = 0
    bright = 0
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            if r >= 250 and g >= 250 and b >= 250:
                whites += 1
            elif min(r, g, b) >= 200:
                bright += 1
    return whites, bright


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/shots_art4")
    entries = eval_code(COLLECT)
    if not isinstance(entries, list) or not entries:
        print("no rails:", entries)
        return
    rails = []
    for entry in entries:
        path, _, rest = entry.partition("|")
        name, _, pos = rest.partition("|")
        x, y, z = (float(v) for v in pos.split(","))
        rails.append((path, name, x, y, z))
    print(f"rails: {len(rails)}")
    quoted = "[" + ", ".join(f'"{p}"' for p, *_ in rails) + "]"

    for idx, (path, name, x, y, z) in enumerate(rails, start=1):
        # Камера в 5 м по диагонали от рейла, на высоте рейла +1.2 м.
        px, py, pz = x + 4.0, y + 1.2, z - 3.0
        print(f"[rail {idx}] {name} at ({x:.2f},{y:.2f},{z:.2f})")
        print("  ", eval_code(MAKE_CAM.format(px=px, py=py, pz=pz, tx=x, ty=y, tz=z)))
        print("  ", eval_code(SET_MAT.format(path="res://assets/materials/metal_pbr_ab_before.tres", paths=quoted)))
        before = shot(out / f"rail{idx}_before.png")
        print("  ", eval_code(SET_MAT.format(path="res://assets/materials/metal_pbr.tres", paths=quoted)))
        after = shot(out / f"rail{idx}_after.png")
        for tag, image in (("before", before), ("after", after)):
            if image is None:
                continue
            stats = white_count(image)
            if stats:
                print(f"  {tag}: pure-white {stats[0]}, near-white {stats[1]}")
    print("  ", eval_code(DROP_CAM))


if __name__ == "__main__":
    main()
