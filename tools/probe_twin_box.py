"""End-to-end check of the twin-box story point on the live instance.

Steps: place the player in the alley, confirm the interactor finds the crate,
start the dialogue through interact(), walk it to the end (choices at b_10),
then verify the flag, the stage and the cut_box trigger.
"""

import json
import socket

PLACE = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'var box = get_tree().current_scene.get_node_or_null("TwinBox")',
    'if p == null or box == null: return "no player or no box"',
    'p.teleport_to(Vector3(8.0, 0.05, -22.3))',
    'p.rotation.y = 0.0',
    'await get_tree().create_timer(0.9).timeout',
    'var it = p.get_interactor()',
    'var tgt = null',
    'if it != null: tgt = it.get_current_target()',
    'var tname := "<null>"',
    'if tgt != null: tname = str(tgt.name)',
    'return "box=%s target=%s dist=%.2f" % [str(box.global_position), tname, p.global_position.distance_to(box.global_position)]',
])

OPEN = "\n".join([
    'var box = get_tree().current_scene.get_node_or_null("TwinBox")',
    'var p = get_tree().get_first_node_in_group("player")',
    'var dm = get_node_or_null("/root/DialogueManager")',
    'if box == null or dm == null: return "missing node"',
    'box.interact(p)',
    'await get_tree().create_timer(0.7).timeout',
    'return "active=%s" % str(dm.is_active())',
])

ADVANCE = "\n".join([
    'var dm = get_node_or_null("/root/DialogueManager")',
    'var quest = get_node_or_null("/root/QuestState")',
    'var steps := 0',
    'var state := ""',
    'while dm.is_active() and steps < 16:',
    '\tvar choices = dm.get("current_choices")',
    '\tvar n := 0',
    '\tif choices is Array: n = choices.size()',
    '\tif n > 0:',
    '\t\tdm.select_choice(0)',
    '\telse:',
    '\t\tdm.advance()',
    '\tsteps += 1',
    '\tawait get_tree().create_timer(0.22).timeout',
    'state = "steps=%d active=%s twin=%s stage=%s" % [steps, str(dm.is_active()), str(quest.has_flag("twin_box_found")), quest.get_current_stage_id()]',
    'return state',
])

AFTER = "\n".join([
    'var cut = get_tree().current_scene.get_node_or_null("Cutscenes")',
    'await get_tree().create_timer(1.5).timeout',
    'var playing := "no-method"',
    'if cut != null and cut.has_method("is_playing"): playing = str(cut.is_playing())',
    'var bb = get_tree().current_scene.get_node_or_null("TwinBox")',
    'var hint := "no-box"',
    'if bb != null and bb.has_method("get_interact_hint"): hint = str(bb.get_interact_hint())',
    'var inter := "?"',
    'if bb != null: inter = str(bb.get_meta("interactable", "?"))',
    'return "cutscene=%s hint=%s interactable_meta=%s" % [playing, hint, inter]',
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


def main():
    for label, code in (("place", PLACE), ("open", OPEN), ("advance", ADVANCE), ("after", AFTER)):
        print(label, call(code))


if __name__ == "__main__":
    main()
