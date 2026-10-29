"""Probe the black half-frame seen from the shop porch (no loops: bridge-safe).

Reports the camera transform, the camera distance, and what a ray from the camera
towards the player hits first — black geometry clipping vs. nothing at all.
"""

import json
import socket

TELEPORT = """
var p := get_tree().get_first_node_in_group("player")
p.teleport_to(Vector3(-4.6, 0.05, -7.4))
p.rotation.y = 0.0
await get_tree().create_timer(1.2).timeout
var cam: Camera3D = p.get_camera()
var space := p.get_world_3d().direct_space_state
var to_player: Vector3 = p.global_position + Vector3(0, 1.5, 0)
var q := PhysicsRayQueryParameters3D.create(cam.global_position, to_player, 1, [p.get_rid()])
var hit := space.intersect_ray(q)
var info := "cam=%s dist=%.2f shape=%s" % [str(cam.global_position), p.get_camera_distance(), cam.get_class()]
if hit.is_empty(): info += " forward_hit=none"
else: info += " forward_hit=%s @%s" % [str(hit.collider.name), str(hit.position)]
return info
"""


def main():
    payload = json.dumps({"command": "eval", "params": {"code": TELEPORT}, "id": 1})
    with socket.create_connection(("127.0.0.1", 9090), timeout=25) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    print(json.loads(buf.decode()))


if __name__ == "__main__":
    main()
