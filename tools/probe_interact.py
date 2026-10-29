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

code = '''var p := get_tree().get_first_node_in_group("player")
var mila = null
for n in get_tree().get_nodes_in_group("npc"): if n.get("npc_id") == "mila": mila = n
if mila == null: return "no mila"
var t: Vector3 = mila.global_position
p.teleport_to(Vector3(t.x, 0.05, t.z + 2.1))
await get_tree().create_timer(0.4).timeout
p.look_at(Vector3(t.x, p.global_position.y + 1.0, t.z))
await get_tree().create_timer(1.3).timeout
var it = p.get_interactor()
var cam = p.get_camera()
return "player=%s dist=%s yaw=%s target=%s enabled=%s cam=%s" % [str(p.global_position), str(snapped(Vector2(p.global_position.x-t.x, p.global_position.z-t.z).length(),0.01)), str(snapped(p.rotation.y,0.001)), str(it.get_current_target()), str(it.interaction_enabled), str(cam.global_position)]
'''
print(call("eval", {"code": code})["result"])
