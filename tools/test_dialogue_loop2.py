import json, socket, time
def call(cmd, params=None):
    p = json.dumps({"command": cmd, "params": params or {}, "id": 1})
    s = socket.create_connection(("127.0.0.1", 9090), timeout=25)
    s.sendall((p + "\n").encode())
    b = b""
    while not b.endswith(b"\n"):
        c = s.recv(1 << 20)
        if not c: break
        b += c
    s.close()
    return json.loads(b.decode())

STATE = '''var dm = get_node_or_null("/root/DialogueManager")
var p := get_tree().get_first_node_in_group("player")
var it = p.get_interactor()
return "%s|%s|enable=%s|tgt=%s|len=%d" % [str(dm.is_active()), dm.get_current_node_id(), str(it.interaction_enabled), str(it.get_current_target() != null), dm.get_current_text().length()]
'''
def st(): return call("eval", {"code": STATE}).get("result")
print("before:", st())
for i in range(1, 16):
    call("key_press", {"key": "E"})
    time.sleep(0.28)
    print(f"{i:02d}", st())
time.sleep(1.2)
print("settled:", st())
