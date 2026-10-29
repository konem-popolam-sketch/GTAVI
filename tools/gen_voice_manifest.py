#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Собирает `scripts/dialogue/data/voice_manifest.json` из JSON-контента диалогов.

Манифест — производный артефакт: `{dialogue_id: {node_id: {speaker, text}}}`.
Он генерируется из `scripts/dialogue/data/*.json`, поэтому текст в манифесте
физически не может разойтись с текстом реплик. Правки в манифест руками не
вносятся — после любой правки диалогов запускаем этот скрипт заново.

Запуск из корня проекта:
    python tools\\gen_voice_manifest.py

Код возврата: 0 — манифест записан, 1 — контент не прочитался.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "scripts" / "dialogue" / "data"
MANIFEST_PATH = DATA_DIR / "voice_manifest.json"


def as_text(value: Any) -> str:
    return "" if value is None else str(value)


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    if not DATA_DIR.is_dir():
        print(f"ОШИБКА: нет каталога {DATA_DIR}")
        return 1

    manifest: dict[str, dict[str, dict[str, str]]] = {}
    files = sorted(
        path for path in DATA_DIR.glob("*.json") if path.name != MANIFEST_PATH.name
    )
    if not files:
        print(f"ОШИБКА: в {DATA_DIR} нет JSON-файлов диалогов")
        return 1

    for path in files:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except OSError as exc:
            print(f"ОШИБКА: {path.name} не читается ({exc})")
            return 1
        except json.JSONDecodeError as exc:
            print(f"ОШИБКА: {path.name} — битый JSON, строка {exc.lineno}: {exc.msg}")
            return 1
        if not isinstance(payload, dict):
            print(f"ОШИБКА: {path.name} — в корне не объект")
            return 1
        for key, dialogue in payload.items():
            dialogue_id = str(key)
            if dialogue_id.startswith("_"):
                continue
            if not isinstance(dialogue, dict):
                print(f"ОШИБКА: {path.name}/{dialogue_id} — не объект")
                return 1
            nodes = dialogue.get("nodes") or {}
            if not isinstance(nodes, dict):
                print(f"ОШИБКА: {path.name}/{dialogue_id}: nodes — не объект")
                return 1
            default_speaker = as_text(dialogue.get("speaker"))
            block: dict[str, dict[str, str]] = {}
            for node_id, node in nodes.items():
                if not isinstance(node, dict):
                    print(f"ОШИБКА: {path.name}/{dialogue_id}/{node_id} — не объект")
                    return 1
                block[str(node_id)] = {
                    "speaker": as_text(node.get("speaker", default_speaker)),
                    "text": as_text(node.get("text")),
                }
            manifest[dialogue_id] = block

    MANIFEST_PATH.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    total = sum(len(block) for block in manifest.values())
    print(
        "[voice_manifest] диалогов %d, реплик %d -> %s"
        % (len(manifest), total, MANIFEST_PATH.relative_to(ROOT).as_posix())
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
