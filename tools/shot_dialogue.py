"""Capture a live dialogue frame: walk-up hint, then the Mila conversation.

Kept as a small script (not a one-liner) because the bridge wraps eval code in
`func _run():` and prefixes each line with a tab, so every statement has to sit at
column 0 with single-line bodies.
"""

import json
import socket
import sys

FEET = (-4.2, 0.05, -8.6)

TELEPORT = (
    'var p := get_tree().get_first_node_in_group("player")\n'
    f"p.teleport_to(Vector3({FEET[0]}, {FEET[1]}, {FEET[2]}))\n"
    'p.rotation.y = atan2(-(-1.6), -(-2.0))\n'
    'if p.has_method("set_controls_enabled"): p.set_controls_enabled(true)\n'
    "await get_tree().create_timer(1.0).timeout\n"
    'return str(p.global_position)'
)

TALK = (
    'var p := get_tree().get_first_node_in_group("player")\n'
    'var mila = null\n'
    'for n in get_tree().get_nodes_in_group("npc"): if n.get("npc_id") == "mila": mila = n\n'
    'if mila == null: return "no mila"\n'
    'mila.interact(p)\n'
    "await get_tree().create_timer(1.2).timeout\n"
    'return "interacted"'
)


def call(command, params=None, timeout=25):
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
    res = call("screenshot", {}, timeout=40)
    data = res.get("data") or res.get("result", {}).get("data")
    if not data:
        print("no screenshot data", res)
        return
    import base64
    from pathlib import Path

    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(base64.b64decode(data))
    print("saved", path)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "docs/shots_final"
    print(call("eval", {"code": TELEPORT}))
    shot(f"{out}/walkup_mila.png")
    print(call("eval", {"code": TALK}))
    shot(f"{out}/dialogue_mila.png")


if __name__ == "__main__":
    main()
