"""Check the two dialogue-exit fixes against the live instance.

1. Esc always leaves a dialogue (even on a choice node, where E is ignored).
2. After the last line closes with E, the RayCast interactor stays disabled for a
   short cooldown, so the same key press cannot reopen the conversation.
"""

import json
import socket
import time

OPEN_MILA = (
    'var p := get_tree().get_first_node_in_group("player")\n'
    'var mila = null\n'
    'for n in get_tree().get_nodes_in_group("npc"): if n.get("npc_id") == "mila": mila = n\n'
    'if mila == null: return "no mila"\n'
    'if get_node("/root/DialogueManager").is_active(): return "already active"\n'
    'mila.interact(p)\n'
    "await get_tree().create_timer(0.3).timeout\n"
    'return "opened"'
)

STATE = (
    'var dm = get_node_or_null("/root/DialogueManager")\n'
    'var p := get_tree().get_first_node_in_group("player")\n'
    'var it = p.get_interactor()\n'
    'return "%s|%s|choices=%d|enable=%s" % [str(dm.is_active()), dm.get_current_node_id(), dm.get_choices().size(), str(it.interaction_enabled)]'
)

ADVANCE = (
    'var dm = get_node_or_null("/root/DialogueManager")\n'
    'dm.advance()\n'
    'return "%s|%s" % [str(dm.is_active()), dm.get_current_node_id()]'
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


def ev(code):
    return call("eval", {"code": code}).get("result")


def state():
    return ev(STATE)


def main():
    call("key_press", {"key": "E"})
    time.sleep(0.7)

    # --- 1. Esc exits a dialogue -------------------------------------------------
    print("open:", ev(OPEN_MILA), "|", state())
    call("key_press", {"key": "ESCAPE"})
    time.sleep(0.4)
    print("after Esc:", state())

    # --- 2. Closing with E must not instantly reopen ----------------------------
    print("reopen:", ev(OPEN_MILA))
    for _ in range(30):
        res = ev(ADVANCE)
        if res.startswith("false"):
            print("closed by advance:", res)
            break
        time.sleep(0.05)
    else:
        print("still active — advance never closed the dialogue")
    print("immediately after close:", state())
    time.sleep(0.8)
    print("0.8s after close:", state())


if __name__ == "__main__":
    main()
