"""List rail-like meshes with positions so camera probes can be aimed exactly."""

import json
import socket

CODE = "\n".join([
    'var out := ""',
    'var found := 0',
    'for n in get_tree().current_scene.find_children("*", "MeshInstance3D", true, false):',
    '\tvar nm := String(n.name)',
    '\tif nm.findn("rail") >= 0 or nm.findn("fence") >= 0 or nm.findn("perimeter") >= 0:',
    '\t\tfound += 1',
    '\t\tout += "%s | %s | aabb %s\\n" % [nm, str(n.global_position), str(n.get_aabb().size)]',
    'return "found=%d\\n%s" % [found, out]',
])


def main():
    payload = json.dumps({"command": "eval", "params": {"code": CODE}, "id": 1})
    with socket.create_connection(("127.0.0.1", 9090), timeout=20) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    print(buf.decode()[:2500])


if __name__ == "__main__":
    main()
