"""Report which cutscenes the player has already seen (proves cut_box auto-started)."""

import json
import socket

CODE = "\n".join([
    'var cut = get_tree().current_scene.get_node_or_null("Cutscenes")',
    'var quest = get_node_or_null("/root/QuestState")',
    'var seen: String = "no-method"',
    'if cut != null and cut.has_method("has_seen"):',
    '\tseen = "box=%s prologue=%s weapon=%s" % [str(cut.has_seen("cut_box")), str(cut.has_seen("cut_prologue")), str(cut.has_seen("cut_weapon"))]',
    'var flags: String = "cut_box_seen=%s" % str(quest.has_flag("cut_box_seen"))',
    'return "%s | %s" % [seen, flags]',
])


def call(code, timeout=30):
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
