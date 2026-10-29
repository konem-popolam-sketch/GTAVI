"""Reproduce (and then prove fixed) the 'dialogue loops forever' bug.

Old behaviour: the E press that closes the last line also feeds the RayCast
interactor in the same frame, so the conversation instantly reopened and E never
got you out. This script walks up to Mila, opens the dialogue and mashes E while
recording `is_active` plus the visible line, so we can see whether the dialogue
closes for good.
"""

import json
import socket
import sys
import time

STATE = (
    'var dm = get_node_or_null("/root/DialogueManager")\n'
    'if dm == null: return "no manager"\n'
    'return "%s|%s|%s" % [str(dm.is_active()), dm.get_current_node_id(), dm.get_current_text().left(28)]'
)

WALK = (
    'var p := get_tree().get_first_node_in_group("player")\n'
    'p.teleport_to(Vector3(-4.2, 0.05, -8.4))\n'
    'p.rotation.y = atan2(-(-2.0), -(-1.6))\n'
    "await get_tree().create_timer(1.6).timeout\n"
    'return str(p.global_position)'
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


def state():
    res = call("eval", {"code": STATE})
    return res.get("result", res)


def press_e():
    return call("key_press", {"key": "E"})


def main():
    print("walk:", call("eval", {"code": WALK}).get("result"))
    press_e()
    time.sleep(0.5)
    print("after Enter (title card):", state())
    press_e()
    time.sleep(0.6)
    print("after first E:", state())
    seq = []
    for _ in range(24):
        press_e()
        time.sleep(0.22)
        seq.append(state())
    for index, item in enumerate(seq, 1):
        print(f"{index:02d} {item}")
    print("hold 1.5s ...")
    time.sleep(1.5)
    print("settled:", state())


if __name__ == "__main__":
    main()
