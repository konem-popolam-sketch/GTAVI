"""Drive the car via the live bridge and report engine audio state."""

import json
import socket
import time

ENTER = "\n".join([
    'var main = get_tree().current_scene',
    'var car = main.get_node_or_null("PlayerCar")',
    'var p = get_tree().get_first_node_in_group("player")',
    'if car == null or p == null: return "no car or player"',
    'p.teleport_to(car.global_position + Vector3(3.0, 0.6, 0.0))',
    'await get_tree().create_timer(0.3).timeout',
    'car.enter(p)',
    'await get_tree().create_timer(0.6).timeout',
    'var eng = car.get_engine_player() if car.has_method("get_engine_player") else null',
    'return "occupied=%s playing=%s bus=%s pitch=%.2f" % [str(car.is_occupied()), str(car.is_engine_audio_playing()), str(eng.bus if eng != null else "-"), (eng.pitch_scale if eng != null else -1.0)]',
])

REV = "\n".join([
    'var main = get_tree().current_scene',
    'var car = main.get_node_or_null("PlayerCar")',
    'if car == null or not car.is_occupied(): return "not driving"',
    'car.set_drive_input(0.0, 1.0, 0.0, true)',
    'await get_tree().create_timer(2.2).timeout',
    'var kmh = car.get_velocity_kmh()',
    'car.set_drive_input(0.0, 0.0, 0.0, false)',
    'var eng = car.get_engine_player()',
    'return "kmh=%.1f pitch=%.2f volume=%.1f playing=%s" % [kmh, eng.pitch_scale, eng.volume_db, str(eng.playing)]',
])

EXIT = "\n".join([
    'var p = get_tree().get_first_node_in_group("player")',
    'var main = get_tree().current_scene',
    'var car = main.get_node_or_null("PlayerCar")',
    'if car != null and car.is_occupied(): car.exit(p)',
    'await get_tree().create_timer(0.8).timeout',
    'return "after exit: occupied=%s playing=%s" % [str(car.is_occupied()), str(car.is_engine_audio_playing())]',
])


def call(code, port=9090, timeout=40):
    payload = json.dumps({"command": "eval", "params": {"code": code}, "id": 1})
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.sendall((payload + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode())


def main():
    for label, code in (("enter", ENTER), ("rev", REV), ("exit", EXIT)):
        print(label, call(code))
        time.sleep(0.5)


if __name__ == "__main__":
    main()
