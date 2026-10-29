"""Close any dialogue left open on the live instance and report its state."""

import json
import socket

CODE = """
var dm = get_node_or_null("/root/DialogueManager")
if dm == null: return "no manager"
var before := "%s|%s" % [str(dm.is_active()), str(dm.get("current_dialogue_id"))]
if dm.is_active(): dm.close()
await get_tree().create_timer(0.6).timeout
return before + " -> " + str(dm.is_active())
"""


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
