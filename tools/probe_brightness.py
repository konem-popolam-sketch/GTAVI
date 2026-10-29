"""Measure night-scene brightness and test transient lighting tweaks live.

Prints mean luminance of the lower half of the frame (the ground the player walks
on) for the current environment, then for a few ambient/exposure variants. Every
change is reverted at the end, so the scene on disk is untouched.
"""

import base64
import io
import json
import socket
import sys

STATE = """
var env := get_viewport().get_camera_3d().get_world_3d().environment
return "%s|%s|%s" % [str(env.ambient_light_energy), str(env.tonemap_exposure), str(env.ambient_light_color)]
"""

SET = """
var env := get_viewport().get_camera_3d().get_world_3d().environment
env.ambient_light_energy = {ambient}
env.tonemap_exposure = {exposure}
await get_tree().create_timer(0.6).timeout
return "set %s|%s" % [str(env.ambient_light_energy), str(env.tonemap_exposure)]
"""

POSITION = """
var p := get_tree().get_first_node_in_group("player")
p.teleport_to(Vector3(0.0, 0.2, 8.0))
p.rotation.y = 0.0
await get_tree().create_timer(1.2).timeout
return str(p.global_position)
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


def shot_bytes():
    res = call("screenshot", {}, timeout=45)
    data = res.get("data") or res.get("result", {}).get("data")
    return base64.b64decode(data) if data else None


def luminance(png_bytes, label, save=None):
    from PIL import Image

    img = Image.open(io.BytesIO(png_bytes)).convert("L")
    w, h = img.size
    ground = img.crop((0, int(h * 0.55), w, h))
    total = img.crop((0, 0, w, h))
    g = sum(ground.getdata()) / float(ground.size[0] * ground.size[1])
    t = sum(total.getdata()) / float(total.size[0] * total.size[1])
    print(f"{label}: ground mean={g:.1f}/255  frame mean={t:.1f}/255")
    if save:
        from pathlib import Path

        Path(save).parent.mkdir(parents=True, exist_ok=True)
        Path(save).write_bytes(png_bytes)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "docs/shots_light"
    print("position:", call("eval", {"code": POSITION}))
    print("state:", call("eval", {"code": STATE}))
    luminance(shot_bytes(), "current", f"{out}/00_before.png")
    variants = [(1.5, 1.2), (1.8, 1.3), (2.2, 1.35)]
    for ambient, exposure in variants:
        print("set:", call("eval", {"code": SET.format(ambient=ambient, exposure=exposure)}))
        luminance(shot_bytes(), f"ambient={ambient} exposure={exposure}", f"{out}/01_a{ambient}_e{exposure}.png")
    # revert to the values found on disk
    print("revert:", call("eval", {"code": SET.format(ambient=1.1, exposure=1.2)}))


if __name__ == "__main__":
    main()
