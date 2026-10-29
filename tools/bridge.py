#!/usr/bin/env python3
"""Thin CLI client for the in-game Godot interaction server (mcp_interaction_server.gd).

Usage:
  python tools/bridge.py info
  python tools/bridge.py cmd <command> '<json params>'      # raw command
  python tools/bridge.py eval '<gdscript exprsession code>' # run expressions, print result
  python tools/bridge.py tree                               # scene tree
  python tools/bridge.py shot out.png                       # screenshot -> file
  python tools/bridge.py nodes                              # node paths (utility)

Environment: GODOT_BRIDGE_PORT (default 9090), GODOT_BRIDGE_TOKEN (default empty).
"""
import base64
import json
import os
import socket
import sys

PORT = int(os.environ.get("GODOT_BRIDGE_PORT", "9090"))
TOKEN = os.environ.get("GODOT_BRIDGE_TOKEN", "")


def call(command, params=None, timeout=60.0):
    payload = {"command": command, "params": params or {}, "id": "1"}
    if TOKEN:
        payload["token"] = TOKEN
    with socket.create_connection(("127.0.0.1", PORT), timeout=timeout) as s:
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    text = buf.decode("utf-8", "replace").strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"raw": text}


def save_screenshot(resp, path):
    if not isinstance(resp, dict):
        return False
    for key in ("image", "image_base64", "data", "png_base64", "base64"):
        val = resp.get(key)
        if isinstance(val, str) and len(val) > 100:
            if val.startswith("data:"):
                val = val.split(",", 1)[1]
            with open(path, "wb") as f:
                f.write(base64.b64decode(val))
            return True
    # fall back: any long string value that decodes as PNG
    for val in resp.values():
        if isinstance(val, str) and len(val) > 500:
            try:
                raw = base64.b64decode(val)
            except Exception:
                continue
            if raw[:8] == b"\x89PNG\r\n\x1a\n":
                with open(path, "wb") as f:
                    f.write(raw)
                return True
    return False


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    action = argv[0]
    if action == "info":
        print(json.dumps(call("get_instance_info"), ensure_ascii=False, indent=2))
    elif action == "cmd":
        params = json.loads(argv[2]) if len(argv) > 2 else {}
        print(json.dumps(call(argv[1], params), ensure_ascii=False)[:4000])
    elif action == "eval":
        code = " ".join(argv[1:])
        resp = call("eval", {"code": code})
        print(json.dumps(resp, ensure_ascii=False)[:4000])
    elif action == "tree":
        resp = call("get_scene_tree")
        print(json.dumps(resp, ensure_ascii=False)[:8000])
    elif action == "shot":
        path = argv[1] if len(argv) > 1 else "shot.png"
        resp = call("screenshot")
        if save_screenshot(resp, path):
            print("saved", path, os.path.getsize(path), "bytes")
        else:
            print(json.dumps(resp, ensure_ascii=False)[:1500])
    else:
        print("unknown action:", action)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
