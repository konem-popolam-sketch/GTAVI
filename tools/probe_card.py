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

code = '''var card = null
var all := get_tree().root.find_children("*", "Control", true, false)
for n in all: if n.has_method("is_open"): card = n
if card == null: return "no card; controls=%d" % all.size()
return "card=%s open=%s dismissed=%s vis=%s" % [str(card.name), str(card.is_open()), str(card.is_dismissed()), str(card.visible)]
'''
print(call("eval", {"code": code}))
