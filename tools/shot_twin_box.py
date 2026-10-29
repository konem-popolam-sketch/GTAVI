"""Screenshot the twin box in the corridor and report whether cut_box started."""

import base64
import json
import socket
from pathlib import Path

STATE = "\n".join([
    'var cut = get_tree().current_scene.get_node_or_null("Cutscenes")',
    'var dm = get_node_or_null("/root/DialogueManager")',
    'var quest = get_node_or_null("/root/QuestState")',
    'var playing := "no-method"',
    'if cut != null and cut.has_method("is_playing"): playing = str(cut.is_playing())',
    'return "cutscene=%s dialogue=%s twin=%s stage=%s" % [playing, str(dm.is_active()), str(quest.has_flag("twin_box_found")), quest.get_current_stage_id()]',
])

CAM = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'var cam = Camera3D.new()',
    'cam.name = "ProbeCamTwin"',
    'get_tree().current_scene.add_child(cam)',
    'cam.global_position = Vector3(5.2, 1.55, -24.4)',
    'cam.look_at(Vector3(8.0, 0.95, -24.5), Vector3.UP)',
    'cam.fov = 60.0',
    'cam.current = true',
    'await get_tree().create_timer(0.8).timeout',
    'return "cam pos=%s" % str(cam.global_position)',
])

RESET = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'p.teleport_to(Vector3(5.4, 0.05, -24.4))',
    'p.rotation.y = -1.5708',
    'await get_tree().create_timer(0.6).timeout',
    'return "ok"',
])

DROP = "\n".join([
    'var cam = get_tree().current_scene.get_node_or_null("ProbeCamTwin")',
    'if cam != null: cam.queue_free()',
    'return "dropped"',
])


def call(code, timeout=40):
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


def shot(path, timeout=40):
    res = call_state = None
    payload = json.dumps({"command": "screenshot", "params": {}, "id": 1})
    with socket.create_connection(("127.0.0.1", 9090), timeout=timeout) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    res = json.loads(buf.decode())
    data = res.get("data") or res.get("result", {}).get("data")
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(base64.b64decode(data))
    print("saved", path, Path(path).stat().st_size)


print("state", call(STATE))
print("reset", call(RESET))
print("cam", call(CAM))
shot("docs/shots_twin_box/01_box_in_corridor.png")
print("drop", call(DROP))
print("state2", call(STATE))
