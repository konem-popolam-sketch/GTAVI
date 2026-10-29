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

def ev(code): return call("eval", {"code": code}).get("result")

STATE = '''var dm = get_node_or_null("/root/DialogueManager")
var p := get_tree().get_first_node_in_group("player")
var it = p.get_interactor()
return "%s|%s|en=%s|tgt=%s" % [str(dm.is_active()), dm.get_current_node_id(), str(it.interaction_enabled), str(it.get_current_target() != null)]
'''
WALK = '''var p := get_tree().get_first_node_in_group("player")
var mila = null
for n in get_tree().get_nodes_in_group("npc"): if n.get("npc_id") == "mila": mila = n
if mila == null: return "no mila"
var t: Vector3 = mila.global_position
p.teleport_to(Vector3(t.x, 0.05, t.z + 2.1))
await get_tree().create_timer(0.4).timeout
p.look_at(Vector3(t.x, p.global_position.y + 1.0, t.z))
await get_tree().create_timer(1.4).timeout
return str(p.get_interactor().get_current_target())
'''
def st(): return call("eval", {"code": STATE}).get("result")

call("key_press", {"key": "E"}); time.sleep(0.7)
print("card dismissed, target:", ev(WALK))
print("pre-open:", st())
call("key_press", {"key": "E"}); time.sleep(0.45)
print("E#1:", st())
for i in range(2, 22):
    if not st().startswith("true"): break
    call("key_press", {"key": "E"}); time.sleep(0.26)
    print("E#%02d:" % i, st())
print("closed:", st())
time.sleep(2.0)
print("after 2s idle:", st())
call("key_press", {"key": "E"}); time.sleep(0.45)
print("E after cooldown (legal reopen):", st())
