import json, base64, socket
def call(c,p=None,t=40):
    s=socket.create_connection(("127.0.0.1",9090),timeout=t)
    s.sendall((json.dumps({"command":c,"params":p or {},"id":1})+"\n").encode())
    b=b""
    while not b.endswith(b"\n"):
        ch=s.recv(1<<20)
        if not ch: break
        b+=ch
    s.close(); return json.loads(b.decode())
code = "\n".join([
 'var p := get_tree().get_first_node_in_group("player")',
 'var mila = null',
 'for n in get_tree().get_nodes_in_group("npc"): if n.get("npc_id") == "mila": mila = n',
 'var hud = get_tree().get_first_node_in_group("hud")',
 'var dm = get_node_or_null("/root/DialogueManager")',
 'if dm.is_active(): dm.close()',
 'await get_tree().create_timer(0.6).timeout',
 'mila.interact(p)',
 'await get_tree().create_timer(0.9).timeout',
 'return "%s|%s" % [str(dm.is_active()), dm.get_current_node_id()]',
])
print(call("eval",{"code":code}).get("result"))
r=call("screenshot"); open("docs/shots_phase2/04_dialogue_hint.png","wb").write(base64.b64decode(r["data"]))
print("saved 04")
