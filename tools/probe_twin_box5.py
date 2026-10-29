"""Walk into the construction corridor (not through the wall) and inspect the twin box."""

import json
import socket

PREP = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'p.teleport_to(Vector3(5.4, 0.05, -24.4))',
    'p.rotation.y = -1.5708',
    'p.set_mouse_captured(true)',
    'await get_tree().create_timer(1.6).timeout',
    'var box = get_tree().current_scene.get_node_or_null("TwinBox")',
    'var it = p.get_interactor()',
    'var tn := "<null>"',
    'if it != null and it.get_current_target() != null:',
    '\ttn = str(it.get_current_target().name)',
    'return "player=%s box=%s target=%s" % [str(p.global_position), str(box.global_position), tn]',
])

TALK = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'var box = get_tree().current_scene.get_node_or_null("TwinBox")',
    'var dm = get_node_or_null("/root/DialogueManager")',
    'box.interact(p)',
    'await get_tree().create_timer(0.8).timeout',
    'var started := dm.is_active()',
    'var steps := 0',
    'while dm.is_active() and steps < 24:',
    '\tif dm.get_choices().size() > 0:',
    '\t\tdm.choose(0)',
    '\telse:',
    '\t\tdm.advance()',
    '\tsteps += 1',
    '\tawait get_tree().create_timer(0.2).timeout',
    'var quest = get_node_or_null("/root/QuestState")',
    'return "started=%s steps=%d twin=%s stage=%s hint=%s meta=%s" % [str(started), steps, str(quest.has_flag("twin_box_found")), quest.get_current_stage_id(), str(box.get_interact_hint()), str(box.get_meta("interactable", "?"))]',
])


def call(code, timeout=60):
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


def main():
    print("prep", call(PREP))
    print("talk", call(TALK))


if __name__ == "__main__":
    main()
