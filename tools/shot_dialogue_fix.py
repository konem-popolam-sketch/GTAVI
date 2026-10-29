"""Live frames for the dialogue-exit fix: open Mila's dialogue, then leave with Esc.

Uses yaw-only rotation (no pitch) so the SpringArm stays at head height while the
camera settles behind the player.
"""

import base64
import json
import socket
import sys
import time
from pathlib import Path


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


def ev(code):
    return call("eval", {"code": code}).get("result")


def shot(path):
    res = call("screenshot")
    data = res.get("data") or res.get("result", {}).get("data")
    if not data:
        print("no screenshot:", res)
        return
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(base64.b64decode(data))
    print("saved", path, Path(path).stat().st_size, "bytes")


PLACE = (
    'var p := get_tree().get_first_node_in_group("player")\n'
    'var mila = null\n'
    'for n in get_tree().get_nodes_in_group("npc"): if n.get("npc_id") == "mila": mila = n\n'
    'if mila == null: return "no mila"\n'
    'var t: Vector3 = mila.global_position\n'
    'p.teleport_to(Vector3(t.x + 0.6, 0.05, t.z + 2.6))\n'
    'p.rotation.y = atan2(-(t.x - p.global_position.x), -(t.z - p.global_position.z))\n'
    "await get_tree().create_timer(2.6).timeout\n"
    'return "%s | target=%s | cam_y=%.2f" % [str(p.global_position), str(p.get_interactor().get_current_target()), p.get_camera().global_position.y]'
)

OPEN = (
    'var dm = get_node_or_null("/root/DialogueManager")\n'
    'if dm.is_active(): return "already open"\n'
    'var p := get_tree().get_first_node_in_group("player")\n'
    'var mila = null\n'
    'for n in get_tree().get_nodes_in_group("npc"): if n.get("npc_id") == "mila": mila = n\n'
    'mila.interact(p)\n'
    "await get_tree().create_timer(0.9).timeout\n"
    'return "%s|%s" % [str(dm.is_active()), dm.get_current_node_id()]'
)

STATE = (
    'var dm = get_node_or_null("/root/DialogueManager")\n'
    'return "%s|%s" % [str(dm.is_active()), dm.get_current_node_id()]'
)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "docs/shots_phase2"
    call("key_press", {"key": "E"})
    time.sleep(0.6)
    print("place:", ev(PLACE))
    shot(f"{out}/00_walkup.png")
    print("open:", ev(OPEN))
    shot(f"{out}/01_dialogue_open.png")
    call("key_press", {"key": "E"})
    time.sleep(0.6)
    print("after E (next line):", ev(STATE))
    shot(f"{out}/02_dialogue_line2.png")
    call("key_press", {"key": "ESCAPE"})
    time.sleep(0.8)
    print("after Esc:", ev(STATE))
    shot(f"{out}/03_after_esc.png")


if __name__ == "__main__":
    main()
