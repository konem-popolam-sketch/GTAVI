"""One-off probe: report why the third-person camera hugs the player.

Every statement stays at column 0 with one-line bodies, because the bridge wraps
eval code in `func _run():` and prefixes each line with a tab.
"""

import json
import socket

CODE = (
    'var out := {}\n'
    'var p := get_tree().get_first_node_in_group("player")\n'
    'out["player"] = p != null\n'
    'if p != null: out["player_pos"] = str(p.global_position)\n'
    'var arm := p.get_node("SpringArm3D")\n'
    'var cam := arm.get_node("Camera3D")\n'
    'out["arm_pos"] = str(arm.global_position)\n'
    'out["cam_pos"] = str(cam.global_position)\n'
    'out["dist"] = cam.global_position.distance_to(arm.global_position)\n'
    'out["spring_length"] = arm.spring_length\n'
    'out["mask"] = arm.collision_mask\n'
    'out["hit_length"] = arm.get_hit_length()\n'
    'return out'
)


def main():
    payload = json.dumps({"command": "eval", "params": {"code": CODE}, "id": 1})
    with socket.create_connection(("127.0.0.1", 9090), timeout=20) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 16)
            if not chunk:
                break
            buf += chunk
    print(buf.decode("utf-8", "replace"))


if __name__ == "__main__":
    main()
