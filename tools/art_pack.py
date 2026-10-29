#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""art_pack.py — одна команда на весь CC0-пак реализма «Ночной смены».

    python tools\\art_pack.py                 # скачать (fetch) + собрать материалы/props.tscn (build)
    python tools\\art_pack.py --dry-run       # ничего не качать, показать выбранные id
    python tools\\art_pack.py --only build    # только пересобрать .tres/props.tscn из манифеста
    python tools\\art_pack.py --verify        # + импорт Godot и headless-прогон 300 кадров

Внутри: tools/fetch_art_assets.py (сеть, Poly Haven CC0) и tools/build_art_pack.py (офлайн-сборка).
--apply-block сюда не пробрасывается намеренно: block.tscn сейчас у level-designer (Эрен, t18),
поэтому по умолчанию его никто не трогает. Отдельно: python tools\\build_art_pack.py --apply-block
"""

import argparse
import os
import subprocess
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

import build_art_pack  # noqa: E402
import fetch_art_assets  # noqa: E402


def log(msg):
    print("[art] " + str(msg), flush=True)


def find_godot():
    for name in ("Godot_v4.7.2-stable_win64_console.exe", "Godot_v4.7.2-stable_win64.exe"):
        path = os.path.join(ROOT, "tools", name)
        if os.path.isfile(path):
            return path
    return None


def run_verify():
    godot = find_godot()
    if not godot:
        log("verify: Godot не найден в tools\\ — пропускаю")
        return False
    import_log = os.path.join(ROOT, "tools", "t_art_import.log")
    log("verify: импорт ресурсов (--headless --import)")
    with open(import_log, "w", encoding="utf-8") as fh:
        import_code = subprocess.call([godot, "--headless", "--path", ROOT, "--import"],
                                      cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT)
    log("verify: импорт exit=%d (%s)" % (import_code, os.path.relpath(import_log, ROOT)))

    hl_log = os.path.join(ROOT, "tools", "t_art_hl.log")
    log("verify: headless 300 кадров")
    code = subprocess.call([godot, "--headless", "--path", ROOT, "--quit-after", "300",
                            "--log-file", hl_log], cwd=ROOT)
    errors = 0
    if os.path.isfile(hl_log):
        with open(hl_log, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "SCRIPT ERROR" in line or "ERROR: Parse" in line:
                    errors += 1
                    log("verify: " + line.rstrip())
    log("verify: exit=%d, SCRIPT ERROR=%d, лог tools/t_art_hl.log" % (code, errors))
    return code == 0 and errors == 0


def main():
    parser = argparse.ArgumentParser(description="CC0-пак реализма: текстуры, материалы, пропсы")
    parser.add_argument("--dry-run", action="store_true", help="только выбрать ассеты, не качать")
    parser.add_argument("--only", choices=["fetch", "build"], default=None,
                        help="выполнить только один шаг")
    parser.add_argument("--verify", action="store_true", help="прогнать Godot headless")
    args = parser.parse_args()

    try:
        if args.only != "build":
            manifest = fetch_art_assets.run(dry_run=args.dry_run)
        else:
            manifest = build_art_pack.load_manifest()
        if args.dry_run:
            log("dry-run: файлы не создавались")
            return 0
        if args.only != "fetch":
            build_art_pack.run()
        log("пак готов: %d наборов текстур, %d моделей"
            % (len(manifest.get("texture_sets", [])), len(manifest.get("models", []))))
    except Exception as exc:  # noqa: BLE001 — печатаем причину и выходим ненулевым кодом
        log("FAILED: %s: %s" % (type(exc).__name__, exc))
        return 2

    if args.verify:
        if not run_verify():
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
