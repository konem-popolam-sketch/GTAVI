"""Inspect meshes near the club facade and report their materials."""

import json
import socket

CODE = "\n".join([
    'var out := ""',
    'var n := 0',
    'for m in get_tree().current_scene.find_children("*", "MeshInstance3D", true, false):',
    '\tvar p: Vector3 = m.global_position',
    '\tif absf(p.x) > 14.0 or p.z < -78.0 or p.z > -30.0:',
    '\t\tcontinue',
    '\tvar mat: Material = m.material_override if m.material_override != null else (m.get_active_material(0) if m.get_surface_override_material_count() >= 0 else null)',
    '\tif m.material_override == null and m.mesh != null and m.mesh.get_surface_count() > 0:',
    '\t\tmat = m.mesh.surface_get_material(0)',
    '\tvar mp := ""',
    '\tif mat != null: mp = str(mat.resource_path)',
    '\tif mp == "": continue',
    '\tn += 1',
    '\tout += "%s | pos %s | %s\\n" % [m.name, str(p), mp.get_file()]',
    'return "near_club=%d\\n%s" % [n, out.substr(0, 2200)]',
])


def main():
    payload = json.dumps({"command": "eval", "params": {"code": CODE}, "id": 1})
    with socket.create_connection(("127.0.0.1", 9090), timeout=25) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    print(buf.decode()[:3000])


if __name__ == "__main__":
    main()
