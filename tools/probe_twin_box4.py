"""Twin-box test from a fresh save: jump the quest to act 2, walk to the crate, inspect it."""

import json
import socket

PREP = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'var ui = get_tree().current_scene.get_node_or_null("UI")',
    'var card = ui.get_node_or_null("TitleCard") if ui != null else null',
    'if card != null and card.has_method("dismiss"): card.dismiss()',
    'var quest = get_node_or_null("/root/QuestState")',
    'quest.set_stage("inspect_twin_box")',
    'await get_tree().create_timer(1.0).timeout',
    'p.teleport_to(Vector3(8.0, 0.05, -23.2))',
    'p.rotation.y = 0.0',
    'p.set_mouse_captured(true)',
    'await get_tree().create_timer(1.6).timeout',
    'var box = get_tree().current_scene.get_node_or_null("TwinBox")',
    'var it = p.get_interactor()',
    'var tn := "<null>"',
    'if it != null and it.get_current_target() != null: tn = str(it.get_current_target().name)',
    'return "stage=%s box_meta=%s target=%s" % [quest.get_current_stage_id(), str(box.get_meta("interactable", "?")), tn]',
])

RUN = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'var it = p.get_interactor()',
    'var dm = get_node_or_null("/root/DialogueManager")',
    'var quest = get_node_or_null("/root/QuestState")',
    'var box = get_tree().current_scene.get_node_or_null("TwinBox")',
    'if it != null and it.get_current_target() != null:',
    '\tit._try_interact()',
    '\tawait get_tree().create_timer(0.8).timeout',
    'var started := dm.is_active()',
    'var steps := 0',
    'while dm.is_active() and steps < 24:',
    '\tif dm.get_choices().size() > 0:',
    '\t\tdm.choose(0)',
    '\telse:',
    '\t\tdm.advance()',
    '\tsteps += 1',
    '\tawait get_tree().create_timer(0.2).timeout',
    'await get_tree().create_timer(1.0).timeout',
    'return "started=%s steps=%d twin=%s stage=%s hint=%s interactable=%s" % [str(started), steps, str(quest.has_flag("twin_box_found")), quest.get_current_stage_id(), str(box.get_interact_hint()), str(box.get_meta("interactable", "?"))]',
])

SHOT_READY = "\n".join([
    'var cut = get_tree().current_scene.get_node_or_null("Cutscenes")',
    'var out := "cut_methods="',
    'if cut != null:',
    '\tfor m in cut.get_method_list():',
    '\t\tif str(m.name).begins_with("is_") or str(m.name).begins_with("get_") and str(m.name).find("play") >= 0:',
    '\t\t\tout += str(m.name) + ","',
    'return out',
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
    print("run", call(RUN))
    print("cut", call(SHOT_READY))


if __name__ == "__main__":
    main()
