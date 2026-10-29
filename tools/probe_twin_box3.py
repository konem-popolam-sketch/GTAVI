"""Twin-box check with the title card dismissed (interactor stays off until then)."""

import json
import socket

START = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'var ui = get_tree().current_scene.get_node_or_null("UI")',
    'var card = ui.get_node_or_null("TitleCard") if ui != null else null',
    'if card != null and card.has_method("dismiss"): card.dismiss()',
    'get_tree().paused = false',
    'await get_tree().create_timer(1.2).timeout',
    'p.teleport_to(Vector3(8.0, 0.05, -23.2))',
    'p.rotation.y = 0.0',
    'p.set_mouse_captured(true)',
    'await get_tree().create_timer(1.4).timeout',
    'var it = p.get_interactor()',
    'var tn := "<null>"',
    'if it != null and it.get_current_target() != null: tn = str(it.get_current_target().name)',
    'var dm = get_node_or_null("/root/DialogueManager")',
    'return "card_open=%s target=%s dialogue_active=%s" % [str(card.is_open() if card != null and card.has_method("is_open") else "?"), tn, str(dm.is_active())]',
])

RUN = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'var it = p.get_interactor()',
    'var tn := "<null>"',
    'if it != null and it.get_current_target() != null: tn = str(it.get_current_target().name)',
    'var dm = get_node_or_null("/root/DialogueManager")',
    'var quest = get_node_or_null("/root/QuestState")',
    'if not dm.is_active():',
    '\tif it != null and it.get_current_target() != null:',
    '\t\tit._try_interact()',
    '\tawait get_tree().create_timer(0.6).timeout',
    'var steps := 0',
    'while dm.is_active() and steps < 24:',
    '\tif dm.get_choices().size() > 0:',
    '\t\tdm.choose(0)',
    '\telse:',
    '\t\tdm.advance()',
    '\tsteps += 1',
    '\tawait get_tree().create_timer(0.18).timeout',
    'return "target=%s steps=%d active=%s twin=%s stage=%s" % [tn, steps, str(dm.is_active()), str(quest.has_flag("twin_box_found")), quest.get_current_stage_id()]',
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
    print("start", call(START))
    print("run", call(RUN))


if __name__ == "__main__":
    main()
