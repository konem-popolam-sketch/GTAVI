"""Visual acceptance pass for the living scene over the Godot bridge (port 9090).

Runs against a *live* game instance (the autoload McpInteractionServer must be
listening). Teleports the player to each point of interest, waits a few frames,
grabs a screenshot per stop, and dumps a JSON report of what the scene contains.

Usage:
  python tools/verify_scene.py --out docs/shots
  python tools/verify_scene.py --out docs/shots --eval-only
"""

import argparse
import json
import socket
import time
from pathlib import Path

HOST, PORT = "127.0.0.1", 9090
STOPS = [
    ("shop", "POI_Shop", (-4.0, 0.0, -10.9)),
    ("pier", "POI_Pier", (0.0, -0.7, 34.5)),
    ("fence", "POI_Fence", (-8.2, 0.0, 11.5)),
    ("alley", "POI_Alley", (4.0, 0.0, -11.6)),
    ("spawn", "PlayerSpawn", (0.0, 0.1, 10.0)),
]

# The bridge wraps eval code in `func _run():` and prefixes every line with a tab,
# so any nested block written with spaces arrives as mixed tabs+spaces and Godot
# rejects it ("Failed to compile GDScript (error 43)"). Keep every statement at
# column 0 and use one-line `for`/`if` bodies: indentation is then irrelevant.
PROBE = (
    "var out := {}\n"
    'var player := get_tree().get_first_node_in_group("player")\n'
    'out["player"] = player != null\n'
    'out["player_pos"] = str(player.global_position) if player else null\n'
    'out["npcs"] = []\n'
    'for n in get_tree().get_nodes_in_group("npc"): out["npcs"].append({"id": n.get("npc_id"), "dialogue": n.get("dialogue_id"), "pos": str(n.global_position)})\n'
    'out["root_children"] = []\n'
    "for c in get_tree().root.get_child(0).get_children(): out[\"root_children\"].append(c.name)\n"
    'out["hud"] = get_tree().root.find_child("HUD", true, false) != null\n'
    'out["dialogue_ui"] = get_tree().root.find_child("DialogueUI", true, false) != null\n'
    "return out"
)


def face_centre_code(pos):
    """One tab-free eval body: teleport, face the quarter centre, let physics settle.

    Yaw is set explicitly because the camera otherwise keeps whatever heading the
    previous stop left behind, which made every run produce different frames.
    """
    x, y, z = pos
    return (
        'var p := get_tree().get_first_node_in_group("player")\n'
        f"if p: p.teleport_to(Vector3({x}, {y}, {z}))\n"
        f"var dx := 0.0 - {x}\n"
        f"var dz := 0.0 - {z}\n"
        "if p: p.rotation.y = atan2(-dx, -dz)\n"
        "if p: p.set_mouse_captured(true)\n"
        # The spring arm smooths its length, so a frame taken right after the
        # teleport shows the camera still travelling -- measured ~2-3 s to settle.
        "await get_tree().create_timer(2.6).timeout\n"
        'return str(p.global_position) if p else "no player"'
    )


def call(command, params=None, timeout=20):
    payload = json.dumps({"command": command, "params": params or {}, "id": 1})
    with socket.create_connection((HOST, PORT), timeout=timeout) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode())


def eval_code(code):
    return call("eval", {"code": code})


def screenshot(path):
    res = call("screenshot", {})
    data = res.get("data") or res.get("result", {}).get("data")
    if not data:
        return res
    import base64

    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(base64.b64decode(data))
    return {"saved": path, "width": res.get("width"), "height": res.get("height")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="docs/shots")
    ap.add_argument("--eval-only", action="store_true")
    args = ap.parse_args()
    out_dir = Path(args.out)

    report = {"probe": eval_code(PROBE)}
    if not args.eval_only:
        shots = []
        for name, poi, pos in STOPS:
            moved = eval_code(face_centre_code(pos))
            path = out_dir / f"poi_{name}.png"
            shot = screenshot(str(path))
            shots.append({"stop": name, "poi": poi, "moved": moved, "shot": shot})
            time.sleep(0.2)
        report["shots"] = shots

    (out_dir / "verify_report.json").parent.mkdir(parents=True, exist_ok=True)
    (out_dir / "verify_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(report, ensure_ascii=True)[:1500])


if __name__ == "__main__":
    main()
