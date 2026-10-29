"""Diagnose twin-box raycast and finish the dialogue with the real choose() API."""

import json
import socket

RAY = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'var box = get_tree().current_scene.get_node_or_null("TwinBox")',
    'var cam = p.get_camera()',
    'var from = cam.global_position',
    'var to = box.global_position + Vector3(0, 0.76, 0)',
    'var q = PhysicsRayQueryParameters3D.create(from, to)',
    'var hit = get_world_3d().direct_space_state.intersect_ray(q)',
    'var hn := "none"',
    'if hit.has("collider") and hit.collider != null: hn = str(hit.collider.name)',
    'var it = p.get_interactor()',
    'var tn := "<null>"',
    'if it != null and it.get_current_target() != null: tn = str(it.get_current_target().name)',
    'return "from=%s to=%s first_hit=%s interactor_target=%s" % [str(from), str(to), hn, tn]',
])

ADV = "\n".join([
    'var dm = get_node_or_null("/root/DialogueManager")',
    'var quest = get_node_or_null("/root/QuestState")',
    'var out := "node=" + str(dm.get_current_node_id()) + " choices=" + str(dm.get_choices().size())',
    'var steps := 0',
    'while dm.is_active() and steps < 20:',
    '\tif dm.get_choices().size() > 0:',
    '\t\tdm.choose(0)',
    '\telse:',
    '\t\tdm.advance()',
    '\tsteps += 1',
    '\tawait get_tree().create_timer(0.2).timeout',
    'out += " -> steps=" + str(steps) + " active=" + str(dm.is_active()) + " stage=" + quest.get_current_stage_id()',
    'return out',
])

MOVE = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'p.teleport_to(Vector3(8.0, 0.05, -23.4))',
    'p.rotation.y = 0.0',
    'p.set_mouse_captured(true)',
    'await get_tree().create_timer(1.0).timeout',
    'var it = p.get_interactor()',
    'var tn := "<null>"',
    'if it != null and it.get_current_target() != null: tn = str(it.get_current_target().name)',
    'return "pos=%s target=%s" % [str(p.global_position), tn]',
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
    print("move", call(MOVE))
    print("ray", call(RAY))
    print("adv", call(ADV))


if __name__ == "__main__":
    main()
