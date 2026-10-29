"""Close the pause menu and unpause the live instance (probe cleanup)."""

import json
import socket

CODE = "\n".join([
    'var pm = get_node_or_null("/root/Main/UI/PauseMenu")',
    'var before = "paused=%s pm=%s" % [str(get_tree().paused), str(pm != null)]',
    'if pm != null and pm.has_method("close"): pm.close()',
    'get_tree().paused = false',
    'await get_tree().create_timer(0.4).timeout',
    'return before + " -> paused=" + str(get_tree().paused)',
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
    print(json.loads(buf.decode()))


if __name__ == "__main__":
    main()
