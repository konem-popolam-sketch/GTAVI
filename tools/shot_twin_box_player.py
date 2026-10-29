"""Game-camera screenshot of the twin box as the player sees it."""

import base64
import json
import socket
from pathlib import Path

PLACE = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'p.teleport_to(Vector3(5.6, 0.05, -24.45))',
    'p.rotation.y = -1.5708',
    'await get_tree().create_timer(1.2).timeout',
    'var cam = p.get_camera()',
    'cam.fov = 70.0',
    'return "player=%s target=%s" % [str(p.global_position), str(p.get_interactor().get_current_target())]',
])


def call(cmd, params=None, timeout=40):
    payload = json.dumps({"command": cmd, "params": params or {}, "id": 1})
    with socket.create_connection(("127.0.0.1", 9090), timeout=timeout) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode())


def main():
    print(call("eval", {"code": PLACE}))
    res = call("screenshot")
    data = res.get("data") or res.get("result", {}).get("data")
    path = Path("docs/shots_twin_box/02_player_view.png")
    path.write_bytes(base64.b64decode(data))
    print("saved", path, path.stat().st_size)


if __name__ == "__main__":
    main()
