import json, socket
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

print(ev('''var p := get_tree().get_first_node_in_group("player")
var mila = null
for n in get_tree().get_nodes_in_group("npc"): if n.get("npc_id") == "mila": mila = n
print("[probe] mila=", mila, " pos=", p.global_position)
var it = p.get_interactor()
return "mila_pos=%s player=%s it_enabled=%s len=%s hit=%s cam=%s" % [str(mila.global_position), str(p.global_position), str(it.enabled), str(it.target_position.length() if it.has_method("get_target_position") else -1), str(it.is_colliding()), str(p.get_camera().global_position)]
'''))
print(ev('''var p := get_tree().get_first_node_in_group("player")
var it = p.get_interactor()
return "ray_len=%s collision_mask=%s enabled=%s units=%s" % [str(it.target_position), str(it.collision_mask), str(it.enabled), str(it.get_collision_mask_value(1))]
'''))
