#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Озвучка реплик «Ночной смены» через Windows SAPI (Microsoft Irina Desktop, ru-RU).

ВНИМАНИЕ: в песочнице DSH SAPI не может писать звук в файл (SelectVoice падает с
«No voice installed…», COM SpFileStream/AudioOutputStream — 0x80045040, WinRT —
«Internal Speech Error»). Для сборки игры используется piper:
`python tools/gen_voice_piper.py` (см. docs/audio/voice.md). Этот скрипт оставлен
рабочим fallback для обычной Windows-машины.

Читает scripts/dialogue/data/voice_manifest.json и вызывает tools/gen_voice.ps1,
который синтезирует WAV в assets/audio/voice/<dialogue_id>_<node_id>.wav.
Вывод PowerShell пишется в лог-файл (не через pipe), затем печатается сводка:
сколько файлов, суммарная длительность, покрытие манифеста и пропущенные узлы.

Примеры:
    python tools/gen_voice.py --dry-run          # что будет сгенерировано
    python tools/gen_voice.py                    # досоздать недостающее
    python tools/gen_voice.py --force            # перегенерировать всё
    python tools/gen_voice.py --only mila        # только один диалог
    python tools/gen_voice.py --sync-manifest    # дописать новые узлы в манифест

После правок текста (Эми присылает новый манифест):
    python tools/gen_voice.py --sync-manifest --force
затем импорт в Godot (см. docs/audio/voice.md).
"""
from __future__ import annotations

import argparse
import array
import json
import math
import subprocess
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "scripts" / "dialogue" / "data"
MANIFEST = DATA_DIR / "voice_manifest.json"
VOICE_DIR = ROOT / "assets" / "audio" / "voice"
PS1 = ROOT / "tools" / "gen_voice.ps1"
PS_LOG = ROOT / "tools" / "gen_voice.log"
RUN_LOG = ROOT / "tools" / "gen_voice_run.log"


def _utf8_stdout() -> None:
    """Русский текст в консоли/лог-файле не должен падать на cp1251."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except Exception:
            pass


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def iter_dialogues() -> dict:
    """Все диалоги из scripts/dialogue/data/*.json (кроме самого манифеста)."""
    found: dict = {}
    for path in sorted(DATA_DIR.glob("*.json")):
        if path.name == "voice_manifest.json":
            continue
        try:
            data = load_json(path)
        except Exception as exc:
            print(f"[warn] пропускаю {path.name}: {exc}")
            continue
        if not isinstance(data, dict):
            continue
        for dialogue_id, dialogue in data.items():
            if isinstance(dialogue, dict) and isinstance(dialogue.get("nodes"), dict):
                found[dialogue_id] = dialogue
    return found


def is_speakable(text: str) -> bool:
    """Есть ли что произносить: «...» и «—» озвучивать не нужно."""
    return any(ch.isalpha() for ch in text or "")


def node_pairs(dialogues: dict) -> list[tuple[str, str, str, str]]:
    """(dialogue_id, node_id, speaker, text) по всем узлам всех диалогов."""
    rows = []
    for dialogue_id, dialogue in dialogues.items():
        default_speaker = str(dialogue.get("speaker", ""))
        nodes = dialogue.get("nodes", {})
        for node_id, node in nodes.items():
            if not isinstance(node, dict):
                continue
            rows.append((
                dialogue_id,
                node_id,
                str(node.get("speaker", default_speaker)),
                str(node.get("text", "")),
            ))
    return rows


def sync_manifest(dialogues: dict) -> tuple[int, int]:
    """Дописать в манифест недостающие пары. Существующие тексты не трогаем."""
    manifest: dict = {}
    if MANIFEST.exists():
        manifest = load_json(MANIFEST)
        if not isinstance(manifest, dict):
            raise SystemExit(f"манифест повреждён (не объект): {MANIFEST}")
    added = 0
    for dialogue_id, node_id, speaker, text in node_pairs(dialogues):
        if not is_speakable(text):
            continue
        bucket = manifest.setdefault(dialogue_id, {})
        if not isinstance(bucket, dict):
            bucket = {}
            manifest[dialogue_id] = bucket
        if node_id in bucket:
            continue
        bucket[node_id] = {"speaker": speaker, "text": text}
        added += 1
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return added, len(manifest)


def wav_info(path: Path) -> dict | None:
    try:
        with wave.open(str(path), "rb") as wf:
            frames = wf.getnframes()
            rate = wf.getframerate()
            channels = wf.getnchannels()
            width = wf.getsampwidth()
            raw = wf.readframes(frames)
    except Exception:
        return None
    peak = 0
    if width == 2 and raw:
        samples = array.array("h")
        samples.frombytes(raw[: len(raw) // 2 * 2])
        if samples:
            peak = max(abs(max(samples)), abs(min(samples)))
    peak_db = 20.0 * math.log10(peak / 32768.0) if peak else -120.0
    return {
        "frames": frames,
        "rate": rate,
        "channels": channels,
        "width": width,
        "duration": frames / float(rate or 1),
        "peak_db": peak_db,
    }


def fmt_duration(seconds: float) -> str:
    total = int(round(seconds))
    return f"{total // 60}:{total % 60:02d} ({seconds:.1f} с)"


def manifest_pairs(manifest: dict, only: str | None) -> list[tuple[str, str]]:
    pairs = []
    for dialogue_id, nodes in manifest.items():
        if str(dialogue_id).startswith("_"):
            continue
        if only and dialogue_id != only:
            continue
        if not isinstance(nodes, dict):
            continue
        for node_id, entry in nodes.items():
            text = ""
            if isinstance(entry, dict):
                text = str(entry.get("text", ""))
            elif isinstance(entry, str):
                text = entry
            if not is_speakable(text):
                continue
            pairs.append((dialogue_id, node_id))
    return pairs


def file_name(dialogue_id: str, node_id: str) -> str:
    return f"{dialogue_id}_{node_id}.wav"


def run_powershell(args) -> int:
    cmd = [
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(PS1),
        "-Manifest", str(MANIFEST),
        "-OutDir", str(VOICE_DIR),
        "-LogPath", str(PS_LOG),
    ]
    if args.force:
        cmd.append("-Force")
    if args.only:
        cmd.extend(["-Only", args.only])

    RUN_LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(RUN_LOG, "w", encoding="utf-8", errors="replace") as fh:
        fh.write(" ".join(cmd) + "\n\n")
        fh.flush()
        proc = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT, cwd=str(ROOT))
    return proc.returncode


def read_summary() -> dict:
    """Разбор tools/gen_voice.log: SUMMARY/FAIL/SKIP_NO_TEXT."""
    result = {"created": 0, "skipped": 0, "no_text": 0, "failed": 0, "total_ms": 0, "fails": []}
    if not PS_LOG.exists():
        return result
    for line in PS_LOG.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("SUMMARY"):
            for token in line.split()[1:]:
                key, _, value = token.partition("=")
                if key in ("created", "skipped", "no_text", "failed", "total_ms"):
                    try:
                        result[key] = int(value)
                    except ValueError:
                        pass
        elif line.startswith("FAIL"):
            result["fails"].append(line)
    return result


def main() -> int:
    _utf8_stdout()
    parser = argparse.ArgumentParser(description="Озвучка реплик «Ночной смены» через SAPI Irina")
    parser.add_argument("--force", action="store_true", help="перезаписать существующие WAV")
    parser.add_argument("--only", metavar="DIALOGUE_ID", help="только один диалог (например mila)")
    parser.add_argument("--dry-run", action="store_true", help="ничего не генерировать, только отчёт")
    parser.add_argument("--sync-manifest", action="store_true",
                        help="дописать в манифест узлы из JSON-диалогов, которых там нет")
    args = parser.parse_args()

    dialogues = iter_dialogues()

    if not MANIFEST.exists():
        if args.dry_run:
            print(f"[dry-run] манифеста нет: {MANIFEST}")
            print("[dry-run] он будет создан из scripts/dialogue/data/*.json при обычном запуске")
            return 1
        added, total = sync_manifest(dialogues)
        print(f"Манифест создан: {MANIFEST} (+{added} реплик, диалогов: {total})")
    elif args.sync_manifest:
        added, total = sync_manifest(dialogues)
        print(f"Манифест дополнен: +{added} реплик (диалогов: {total})")
        if added == 0:
            print("Новых узлов нет — манифест уже полный.")

    manifest = load_json(MANIFEST)
    pairs = manifest_pairs(manifest, args.only)

    all_rows = node_pairs(dialogues)
    speakable_rows = [r for r in all_rows if is_speakable(r[3])]
    silent_rows = [r for r in all_rows if not is_speakable(r[3])]

    expected = [file_name(d, n) for d, n in pairs]
    present = [name for name in expected if (VOICE_DIR / name).exists()]
    missing = [name for name in expected if not (VOICE_DIR / name).exists()]
    coverage = (len(present) / len(expected) * 100.0) if expected else 0.0

    if args.dry_run:
        print()
        print("=== ПРОГНОЗ (dry-run) ===")
        print(f"Манифест: {MANIFEST.relative_to(ROOT)}")
        print(f"Пар в манифесте к озвучке: {len(expected)}")
        print(f"Узлов в диалогах: {len(all_rows)}; с произносимым текстом: {len(speakable_rows)}")
        print(f"На диске уже есть: {len(present)}; будет сгенерировано: {len(missing)}")
        print(f"Покрытие сейчас: {len(present)}/{len(expected)} ({coverage:.1f}%)")
        if silent_rows:
            silent = ", ".join(f"{d}/{n}" for d, n, _, _ in silent_rows)
            print(f"Узлы без произносимого текста (не озвучиваются): {silent}")
        if missing and len(missing) <= 12:
            print("Не хватает: " + ", ".join(missing))
        return 0

    if not PS1.exists():
        print(f"ОШИБКА: нет скрипта синтеза {PS1}")
        return 2

    print(f"Генерация: {len(expected)} реплик (--force={args.force}, --only={args.only or 'все'})…")
    rc = run_powershell(args)
    summary = read_summary()

    print(f"PowerShell: код возврата {rc}; лог {PS_LOG.relative_to(ROOT)}")
    if summary["failed"] and summary["fails"]:
        for line in summary["fails"][:10]:
            print("  " + line)

    if summary["skipped"] and not args.force:
        print(f"Пропущено (файлы уже есть): {summary['skipped']} — перезапись только с --force")

    # Пересчёт после генерации.
    present = [name for name in expected if (VOICE_DIR / name).exists()]
    missing = [name for name in expected if not (VOICE_DIR / name).exists()]
    coverage = (len(present) / len(expected) * 100.0) if expected else 0.0

    total_seconds = 0.0
    bad_format = 0
    hot_files = []
    checked = []
    for name in present:
        info = wav_info(VOICE_DIR / name)
        if info is None:
            bad_format += 1
            continue
        total_seconds += info["duration"]
        if info["rate"] != 44100 or info["channels"] != 1 or info["width"] != 2:
            bad_format += 1
        if info["peak_db"] > -0.9:
            hot_files.append(name)
        checked.append((name, info["duration"], info["peak_db"]))

    print()
    print("=== ИТОГ ===")
    print(f"Сгенерировано сейчас: {summary['created']}")
    print(f"Файлов на диске: {len(present)} из {len(expected)} ожидаемых")
    print(f"Суммарная длительность: {fmt_duration(total_seconds)}")
    print(f"Покрытие манифеста: {len(present)}/{len(expected)} ({coverage:.1f}%)")
    if speakable_rows:
        covered_nodes = sum(
            1 for d, n, _, _ in speakable_rows
            if (VOICE_DIR / file_name(d, n)).exists()
        )
        print(f"Покрытие узлов диалогов: {covered_nodes}/{len(speakable_rows)} "
              f"({covered_nodes / len(speakable_rows) * 100.0:.1f}% озвучиваемых узлов, "
              f"всего узлов {len(all_rows)})")
    if silent_rows:
        silent = ", ".join(f"{d}/{n}" for d, n, _, _ in silent_rows)
        print(f"Без озвучки (текст не произносится): {silent}")
    if bad_format:
        print(f"ВНИМАНИЕ: файлов не в формате PCM16/44.1k/mono: {bad_format}")
    if hot_files:
        print(f"ВНИМАНИЕ: пик выше −1 dBFS у файлов: {', '.join(hot_files[:10])}")
    else:
        print("Пик: все файлы ≤ −1 dBFS")

    if checked:
        sample = checked[:3]
        print("Проверочные файлы:")
        for name, duration, peak in sample:
            print(f"  {name}: {duration:.2f} с, пик {peak:.2f} dBFS")

    if missing:
        print(f"Не хватает {len(missing)} файлов: {', '.join(missing[:15])}"
              + (" …" if len(missing) > 15 else ""))
        if not summary["created"] and RUN_LOG.exists():
            tail = RUN_LOG.read_text(encoding="utf-8", errors="replace").strip().splitlines()[-12:]
            print("--- хвост tools/gen_voice_run.log ---")
            for line in tail:
                print("  " + line)
        return 1
    if summary["failed"]:
        print(f"ОШИБОК синтеза: {summary['failed']}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
