"""Probe the interactor ray itself: where it starts, where it points, what it hits."""

import json
import socket

CODE = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'var it = p.get_interactor() as Node3D',
    'var cam = p.get_camera() as Node3D',
    'var from: Vector3 = it.global_position',
    'var to: Vector3 = it.to_global(it.target_position)',
    'var q := PhysicsRayQueryParameters3D.create(from, to)',
    'var hit: Dictionary = it.get_world_3d().direct_space_state.intersect_ray(q)',
    'var hn: String = "none"',
    'var hp: Vector3 = Vector3.ZERO',
    'if hit.size() > 0:',
    '\tvar col = hit.get("collider")',
    '\tif col != null: hn = str(col.name)',
    '\thp = hit.get("position")',
    'var cam_from: Vector3 = cam.global_position',
    'var cam_to: Vector3 = cam.to_global(Vector3(0, 0, -6))',
    'var q2 := PhysicsRayQueryParameters3D.create(cam_from, cam_to)',
    'var hit2: Dictionary = it.get_world_3d().direct_space_state.intersect_ray(q2)',
    'var hn2: String = "none"',
    'if hit2.size() > 0:',
    '\tvar col2 = hit2.get("collider")',
    '\tif col2 != null: hn2 = str(col2.name)',
    'return "it_pos=%s it_to=%s hit=%s at=%s | cam=%s camhit=%s" % [str(from), str(to), hn, str(hp), str(cam_from), hn2]',
])


def call(code, timeout=40):
    payload = json.dumps({"command": "eval", "params": {"code": code}, "id": 1})
    with socket.create_connection(("127.0.0.1", 9090), timeout=timeout) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode())


print(call(CODE))
