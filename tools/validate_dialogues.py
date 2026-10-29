#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Валидатор контента диалогов «Ночной смены» (фаза 2, схема v2).

Что проверяет:
  * JSON читается и держит схему `{dialogue_id: {title, speaker, start, nodes}}`;
  * у каждого узла есть текст; `next`/`choices` ведут только в существующие узлы;
  * у узла с выбором 1–3 варианта, у каждого варианта есть текст и `next`,
    а сам узел не тащит одновременно `next` (менеджер его всё равно игнорирует);
  * `effect`/`ending` корректных типов; финальный узел никуда не ведёт;
  * достижимость: все узлы достижимы из `start`, и из каждого можно дойти до конца
    (висячих петель и осиротевших реплик нет);
  * объёмы фазы 2: >= 7 диалогов, >= 120 узлов, >= 12 узлов с выбором, 3 концовки;
  * `voice_manifest.json` покрывает 100% узлов, и speaker/text в нём посимвольно
    совпадают с JSON — манифест это источник озвучки, расхождение = неверные субтитры.

Запуск из корня проекта:
    python tools\\validate_dialogues.py

Код возврата: 0 — ошибок нет (предупреждения допустимы), 1 — есть ошибки.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "scripts" / "dialogue" / "data"
MANIFEST_PATH = DATA_DIR / "voice_manifest.json"
MANIFEST_NAME = "voice_manifest.json"

MIN_DIALOGUES = 7
MIN_NODES = 120
MIN_CHOICE_NODES = 12
MIN_ENDINGS = 3
MAX_CHOICES = 3
MAX_TEXT_LENGTH = 220
EFFECT_KEYS = {"objective", "set_flag", "flags"}
CHOICE_KEYS = {"text", "next", "requires"}
NODE_KEYS = {
    "speaker", "text", "next", "choices", "effect", "ending", "ending_title", "voice_id",
}
DIALOGUE_KEYS = {"title", "speaker", "start", "nodes"}
MANIFEST_IGNORED_KEYS = {"_meta", "meta", "version", "settings"}

## Контракт docs/story_tasks.md: сколько узлов ждёт Тору в каждом диалоге.
CONTRACT_NODES = {
    "mila": 10,
    "mila_watcher": 7,
    "kostya": 10,
    "foreman": 10,
    "voice": 15,  # 11 старых + 4 новых (док считает 14 — старое число)
    "voice_log": 8,
    "galya": 14,
    "timur": 12,
    "twin_box": 12,
    "mila_late": 12,
    "foreman_late": 14,
    "kostya_late": 9,
    "finale": 16,
    "amb_cat": 3,
    "amb_bus": 3,
    "amb_puddle": 3,
    "amb_radio": 3,
    # Ветка «Ствол» (t37): 5 диалогов + 4 катсценных блока.
    "kostya_gun": 8,
    "weapon_pickup": 3,
    "timur_gun": 6,
    "guard_confront": 10,
    "guard_aftermath": 5,
    "cut_prologue": 2,
    "cut_box": 4,
    "cut_weapon": 5,
    "cut_weapon_alt": 3,
}
CONTRACT_DIALOGUES = len(CONTRACT_NODES)

## Флаги из docs/story_bible.md §7.1 — опечатку в имени поймаем здесь.
KNOWN_FLAGS = {
    "mila_warned", "mila_watched", "kostya_told", "package_delivered",
    "ending_delivered", "ending_opened", "night_started", "shift_log_seen",
    "galya_deal", "site_code", "item_flashlight", "timur_friend",
    "twin_box_found", "twin_off", "cable_cut", "mila_confessed", "mila_promise",
    "foreman_cornered", "kostya_witness", "voice_second_call",
    "amb_cat_seen", "amb_bus_seen", "amb_puddle_seen", "amb_radio_seen",
    "ending_silence", "ending_voice", "ending_shift",
    # Ветка «Ствол» (t31/t37): 13 флагов, из них три исхода у шлагбаума
    # (weapon_discharged / weapon_brandished / weapon_holstered) и weapon_disposed —
    # точки невозврата, остальные девять — запись состояния.
    "weapon_hint", "weapon_hint_done", "weapon_found", "weapon_drawn",
    "timur_saw_weapon", "timur_silent", "guard_confronted",
    "weapon_discharged", "weapon_brandished", "guard_note", "weapon_holstered",
    "guard_aftermath_seen", "weapon_disposed",
}


class Report:
    """Копилка ошибок/предупреждений и счётчиков для итогового отчёта."""

    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.dialogues: list[str] = []
        self.nodes_total = 0
        self.choice_nodes = 0
        self.choices_total = 0
        self.endings: dict[int, str] = {}
        self.ending_nodes: list[tuple[str, str]] = []
        self.speakers: set[str] = set()
        self.requires_usage = 0

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def as_text(value: Any) -> str:
    """None и нестроки приводим к строке — так же, как это делает dialogue_data.gd."""
    if value is None:
        return ""
    return str(value)


def load_json(path: Path, report: Report) -> Any:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        report.error(f"{rel(path)}: файл не читается ({exc})")
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        report.error(
            f"{rel(path)}: битый JSON — строка {exc.lineno}, колонка {exc.colno}: {exc.msg}"
        )
        return None


def check_flag_name(flag: str, where: str, report: Report) -> None:
    name = flag.strip()
    if not name:
        report.error(f"{where}: пустое имя флага")
        return
    if name not in KNOWN_FLAGS:
        report.warn(f"{where}: флаг '{name}' не из списка docs/story_bible.md §7.1")


def check_effect(node_id: str, effect: Any, where: str, report: Report) -> None:
    if effect is None:
        return
    if not isinstance(effect, dict):
        report.error(f"{where}/{node_id}: effect — не объект")
        return
    for key in effect:
        if key not in EFFECT_KEYS:
            report.warn(f"{where}/{node_id}: неизвестный ключ effect '{key}' (менеджер его не применит)")
    objective = effect.get("objective")
    if objective is not None and (not isinstance(objective, str) or not objective.strip()):
        report.error(f"{where}/{node_id}: effect.objective должен быть непустой строкой")
    flag = effect.get("set_flag")
    if flag is not None:
        if isinstance(flag, str):
            check_flag_name(flag, f"{where}/{node_id}.set_flag", report)
        elif isinstance(flag, list):
            if not flag:
                report.warn(f"{where}/{node_id}: effect.set_flag — пустой массив")
            for item in flag:
                if not isinstance(item, str) or not item.strip():
                    report.error(f"{where}/{node_id}: effect.set_flag содержит не строку: {item!r}")
                else:
                    check_flag_name(item, f"{where}/{node_id}.set_flag", report)
        else:
            report.error(f"{where}/{node_id}: effect.set_flag — не строка и не массив")
    flags = effect.get("flags")
    if flags is not None:
        if not isinstance(flags, dict):
            report.error(f"{where}/{node_id}: effect.flags — не объект")
        else:
            for key, value in flags.items():
                if not isinstance(key, str) or not key.strip():
                    report.error(f"{where}/{node_id}: effect.flags с пустым ключом")
                    continue
                check_flag_name(key, f"{where}/{node_id}.flags", report)
                if not isinstance(value, (bool, str)):
                    report.warn(
                        f"{where}/{node_id}: effect.flags['{key}'] — не bool и не строка "
                        f"({type(value).__name__})"
                    )


def check_node(
    dialogue_id: str,
    node_id: str,
    node: Any,
    nodes: dict[str, Any],
    default_speaker: str,
    report: Report,
) -> None:
    where = f"{dialogue_id}.{node_id}"
    if not isinstance(node, dict):
        report.error(f"{where}: узел — не объект")
        return
    unknown = [key for key in node if key not in NODE_KEYS]
    if unknown:
        report.warn(f"{where}: неизвестные поля узла: {', '.join(sorted(unknown))}")

    text = node.get("text")
    if not isinstance(text, str) or not text.strip():
        report.error(f"{where}: пустой text")
    else:
        if len(text) > MAX_TEXT_LENGTH:
            report.warn(f"{where}: text длиной {len(text)} символов (> {MAX_TEXT_LENGTH}, субтитр не влезет в две строки)")
        if text != text.strip():
            report.warn(f"{where}: text с ведущими/хвостовыми пробелами")

    speaker = node.get("speaker", default_speaker)
    if not isinstance(speaker, str) or not speaker.strip():
        report.error(f"{where}: пустой speaker")
    else:
        report.speakers.add(speaker.strip())

    voice_id = node.get("voice_id")
    if voice_id is not None and (not isinstance(voice_id, str) or not voice_id.strip()):
        report.error(f"{where}: voice_id должен быть непустой строкой")

    choices = node.get("choices")
    has_choices = isinstance(choices, list) and len(choices) > 0
    if choices is not None and not isinstance(choices, list):
        report.error(f"{where}: choices — не массив")
        has_choices = False
    if isinstance(choices, list) and len(choices) == 0:
        report.warn(f"{where}: пустой массив choices — лучше убрать поле")
    if isinstance(choices, list):
        if len(choices) > MAX_CHOICES:
            report.error(f"{where}: {len(choices)} вариантов, максимум {MAX_CHOICES}")
        for index, choice in enumerate(choices):
            label = f"{where}.choices[{index}]"
            if not isinstance(choice, dict):
                report.error(f"{label}: вариант — не объект")
                continue
            for key in choice:
                if key not in CHOICE_KEYS:
                    report.warn(f"{label}: неизвестное поле '{key}'")
            choice_text = choice.get("text")
            if not isinstance(choice_text, str) or not choice_text.strip():
                report.error(f"{label}: пустой text")
            elif len(choice_text) > MAX_TEXT_LENGTH:
                report.warn(f"{label}: text длиной {len(choice_text)} символов (> {MAX_TEXT_LENGTH})")
            choice_next = choice.get("next")
            if not isinstance(choice_next, str) or not choice_next.strip():
                report.error(f"{label}: нет next (вариант должен вести в узел)")
            elif choice_next not in nodes:
                report.error(f"{label}: next '{choice_next}' указывает на несуществующий узел")
            requires = choice.get("requires")
            if requires is not None:
                report.requires_usage += 1
                if not isinstance(requires, list) or not requires:
                    report.error(f"{label}: requires должен быть непустым массивом флагов")
                else:
                    if len(set(map(str, requires))) != len(requires):
                        report.warn(f"{label}: requires с повторами")
                    for flag in requires:
                        if not isinstance(flag, str) or not flag.strip():
                            report.error(f"{label}: requires содержит не строку: {flag!r}")
                        elif flag not in KNOWN_FLAGS:
                            report.warn(f"{label}: requires с неизвестным флагом '{flag}'")

    next_id = node.get("next")
    if next_id is not None and not isinstance(next_id, str):
        report.error(f"{where}: next — не строка и не null")
    next_str = as_text(next_id)
    if next_str:
        if next_str not in nodes:
            report.error(f"{where}: next '{next_str}' указывает на несуществующий узел")
        if has_choices:
            report.error(f"{where}: одновременно next и choices — next будет проигнорирован")

    check_effect(node_id, node.get("effect"), dialogue_id, report)

    if "ending" in node:
        ending = node.get("ending")
        if not isinstance(ending, int) or isinstance(ending, bool) or ending <= 0:
            report.error(f"{where}: ending должен быть целым > 0")
        else:
            report.endings[ending] = as_text(node.get("ending_title")).strip()
            report.ending_nodes.append((dialogue_id, node_id))
            if not report.endings[ending]:
                report.error(f"{where}: у концовки {ending} нет ending_title")
            if next_str:
                report.error(f"{where}: у финального узла не должно быть next")
            if has_choices:
                report.error(f"{where}: у финального узла не должно быть choices")
    elif "ending_title" in node:
        report.warn(f"{where}: ending_title без ending — титр не покажется")

    if has_choices:
        report.choice_nodes += 1
        report.choices_total += len(choices)


def transitions(node: dict[str, Any], nodes: dict[str, Any]) -> list[str]:
    """Все переходы узла, ведущие в реально существующие узлы."""
    result: list[str] = []
    next_str = as_text(node.get("next"))
    if next_str and next_str in nodes:
        result.append(next_str)
    choices = node.get("choices")
    if isinstance(choices, list):
        for choice in choices:
            if isinstance(choice, dict):
                choice_next = as_text(choice.get("next"))
                if choice_next and choice_next in nodes:
                    result.append(choice_next)
    return result


def check_reachability(dialogue_id: str, nodes: dict[str, Any], start: str, report: Report) -> None:
    if start not in nodes:
        return  # об этой ошибке уже сказано в check_dialogue
    graph: dict[str, list[str]] = {}
    for node_id, node in nodes.items():
        if isinstance(node, dict):
            graph[node_id] = transitions(node, nodes)
        else:
            graph[node_id] = []

    seen: set[str] = set()
    queue = [start]
    while queue:
        current = queue.pop()
        if current in seen:
            continue
        seen.add(current)
        queue.extend(graph.get(current, []))

    unreachable = sorted(set(nodes) - seen)
    if unreachable:
        preview = ", ".join(unreachable[:8])
        suffix = f" (+{len(unreachable) - 8})" if len(unreachable) > 8 else ""
        report.error(f"{dialogue_id}: недостижимые из start '{start}' узлы: {preview}{suffix}")

    terminals = {node_id for node_id, links in graph.items() if not links}
    if not terminals:
        report.error(f"{dialogue_id}: нет финальных узлов — диалог нечем закончить")
        return
    reverse: dict[str, list[str]] = {node_id: [] for node_id in graph}
    for node_id, links in graph.items():
        for target in links:
            reverse[target].append(node_id)
    can_finish = set(terminals)
    queue = list(terminals)
    while queue:
        current = queue.pop()
        for parent in reverse.get(current, []):
            if parent not in can_finish:
                can_finish.add(parent)
                queue.append(parent)
    stuck = sorted(set(graph) - can_finish)
    if stuck:
        preview = ", ".join(stuck[:8])
        suffix = f" (+{len(stuck) - 8})" if len(stuck) > 8 else ""
        report.error(
            f"{dialogue_id}: из узлов нельзя дойти до конца (зациклятся): {preview}{suffix}"
        )


def check_dialogue(dialogue_id: str, dialogue: Any, report: Report) -> dict[str, Any] | None:
    if not isinstance(dialogue, dict):
        report.error(f"{dialogue_id}: диалог — не объект")
        return None
    unknown = [key for key in dialogue if key not in DIALOGUE_KEYS]
    if unknown:
        report.warn(f"{dialogue_id}: неизвестные поля диалога: {', '.join(sorted(unknown))}")

    title = dialogue.get("title")
    if not isinstance(title, str) or not title.strip():
        report.warn(f"{dialogue_id}: нет title (в отладке будет безымянным)")

    default_speaker = dialogue.get("speaker")
    if not isinstance(default_speaker, str) or not default_speaker.strip():
        report.error(f"{dialogue_id}: нет speaker по умолчанию — часть реплик останется без имени")

    nodes = dialogue.get("nodes")
    if not isinstance(nodes, dict) or not nodes:
        report.error(f"{dialogue_id}: нет непустого объекта nodes")
        return None

    for node_id, node in nodes.items():
        check_node(
            dialogue_id,
            str(node_id),
            node,
            nodes,
            as_text(default_speaker).strip(),
            report,
        )

    start = as_text(dialogue.get("start")).strip()
    if not start:
        report.error(f"{dialogue_id}: нет start")
    elif start not in nodes:
        report.error(f"{dialogue_id}: start '{start}' отсутствует среди узлов")
    else:
        check_reachability(dialogue_id, nodes, start, report)

    report.nodes_total += len(nodes)
    return dialogue


def expected_voice_key(node: dict[str, Any]) -> str:
    voice_id = as_text(node.get("voice_id")).strip()
    return voice_id or ""


def check_manifest(dialogues: dict[str, dict[str, Any]], report: Report) -> None:
    if not MANIFEST_PATH.exists():
        report.warn(
            f"{rel(MANIFEST_PATH)}: манифеста нет — озвучки не будет, диалоги пойдут на субтитрах"
        )
        return
    manifest = load_json(MANIFEST_PATH, report)
    if manifest is None:
        return
    if not isinstance(manifest, dict) or not manifest:
        report.error(f"{rel(MANIFEST_PATH)}: ожидался непустой объект")
        return

    manifest_dialogues = {
        key: value
        for key, value in manifest.items()
        if key not in MANIFEST_IGNORED_KEYS and not str(key).startswith("_")
    }
    covered = 0
    expected: set[tuple[str, str]] = set()

    for dialogue_id, dialogue in dialogues.items():
        dialogue_entry = manifest_dialogues.get(dialogue_id)
        if not isinstance(dialogue_entry, dict):
            report.error(f"voice_manifest: нет блока диалога '{dialogue_id}' — 0% озвучки")
            continue
        nodes = dialogue.get("nodes") or {}
        default_speaker = as_text(dialogue.get("speaker")).strip()
        for node_id, node in nodes.items():
            if not isinstance(node, dict):
                continue
            voice_id = expected_voice_key(node)
            entry_key = voice_id or str(node_id)
            expected.add((dialogue_id, entry_key))
            entry = dialogue_entry.get(entry_key)
            if not isinstance(entry, dict):
                report.error(f"voice_manifest: нет реплики '{dialogue_id}/{entry_key}'")
                continue
            manifest_text = entry.get("text")
            node_text = as_text(node.get("text"))
            if manifest_text != node_text:
                report.error(
                    f"voice_manifest: текст '{dialogue_id}/{entry_key}' не совпадает с JSON "
                    f"(манифест: {as_text(manifest_text)[:60]!r}…, JSON: {node_text[:60]!r}…)"
                )
            manifest_speaker = as_text(entry.get("speaker")).strip()
            node_speaker = as_text(node.get("speaker", default_speaker)).strip()
            if manifest_speaker != node_speaker:
                report.error(
                    f"voice_manifest: speaker '{dialogue_id}/{entry_key}' "
                    f"'{manifest_speaker}' != '{node_speaker}'"
                )
            covered += 1

    for dialogue_id, dialogue_entry in manifest_dialogues.items():
        if dialogue_id not in dialogues:
            report.error(f"voice_manifest: блок '{dialogue_id}' без такого диалога в JSON")
            continue
        if not isinstance(dialogue_entry, dict):
            report.error(f"voice_manifest: блок '{dialogue_id}' — не объект")
            continue
        for entry_key in dialogue_entry:
            if (dialogue_id, str(entry_key)) not in expected:
                report.error(
                    f"voice_manifest: лишняя запись '{dialogue_id}/{entry_key}' — "
                    f"такого узла/voice_id в JSON нет"
                )

    total = report.nodes_total
    if total and covered < total:
        report.error(f"voice_manifest: покрыто {covered} из {total} узлов ({covered * 100 // total}%)")


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    report = Report()
    print("=== Валидатор диалогов «Ночной смены» (схема v2) ===")
    print(f"Каталог: {rel(DATA_DIR)}")

    if not DATA_DIR.is_dir():
        print(f"ОШИБКА: каталога {rel(DATA_DIR)} нет")
        return 1

    files = sorted(
        path for path in DATA_DIR.glob("*.json") if path.name != MANIFEST_NAME
    )
    if not files:
        print("ОШИБКА: в каталоге нет JSON-файлов диалогов")
        return 1

    dialogues: dict[str, dict[str, Any]] = {}
    for path in files:
        payload = load_json(path, report)
        if payload is None:
            continue
        if not isinstance(payload, dict):
            report.error(f"{rel(path)}: в корне ожидался объект")
            continue
        for key, value in payload.items():
            dialogue_id = str(key)
            if dialogue_id.startswith("_"):
                continue
            if dialogue_id in dialogues:
                report.error(f"{rel(path)}: диалог '{dialogue_id}' уже объявлен в другом файле")
                continue
            parsed = check_dialogue(dialogue_id, value, report)
            if parsed is not None:
                dialogues[dialogue_id] = parsed

    check_manifest(dialogues, report)

    # --- Контракт docs/story_tasks.md -------------------------------------
    if report.ending_nodes:
        ending_dialogues = {dialogue_id for dialogue_id, _ in report.ending_nodes}
        if len(ending_dialogues) > 1:
            report.error(
                "ending/ending_title должны быть только в 'finale', а встречаются в: "
                + ", ".join(sorted(ending_dialogues))
            )
        if len(report.ending_nodes) != MIN_ENDINGS:
            report.error(
                f"концовок должно быть ровно {MIN_ENDINGS}, найдено {len(report.ending_nodes)}"
            )
    else:
        report.error("в контенте нет ни одной концовки (ending/ending_title)")
    if len(dialogues) != CONTRACT_DIALOGUES:
        report.warn(
            f"контракт story_tasks.md ждёт {CONTRACT_DIALOGUES} диалогов, сейчас {len(dialogues)}"
        )
    for dialogue_id, expected in CONTRACT_NODES.items():
        if dialogue_id not in dialogues:
            report.warn(f"контракт: нет диалога '{dialogue_id}'")
            continue
        actual = len(dialogues[dialogue_id].get("nodes") or {})
        if actual != expected:
            report.warn(f"{dialogue_id}: {actual} узлов, контракт ждёт {expected}")
    if report.requires_usage:
        report.warn(
            "есть requires у вариантов выбора — DialogueManager (t16, Ичиго) пока их не "
            "фильтрует: третий вариант финала будет виден всегда, пока не добавят проверку"
        )

    # --- Сводка ------------------------------------------------------------
    print()
    print("Диалоги:")
    for dialogue_id, dialogue in dialogues.items():
        nodes = dialogue.get("nodes") or {}
        choice_nodes = sum(
            1
            for node in nodes.values()
            if isinstance(node, dict) and isinstance(node.get("choices"), list) and node["choices"]
        )
        endings = sorted(
            int(node["ending"])
            for node in nodes.values()
            if isinstance(node, dict)
            and isinstance(node.get("ending"), int)
            and not isinstance(node.get("ending"), bool)
            and node["ending"] > 0
        )
        suffix = f", концовки {endings}" if endings else ""
        print(f"  - {dialogue_id:<14} узлов {len(nodes):>3}, с выбором {choice_nodes}{suffix}")

    print()
    print(f"Итого: диалогов {len(dialogues)}, узлов {report.nodes_total}, "
          f"узлов с выбором {report.choice_nodes} (вариантов {report.choices_total}), "
          f"концовок {len(report.endings)}")
    print(f"Спикеры ({len(report.speakers)}): {', '.join(sorted(report.speakers)) or '—'}")

    thresholds = [
        ("диалогов", len(dialogues), MIN_DIALOGUES),
        ("узлов", report.nodes_total, MIN_NODES),
        ("узлов с выбором", report.choice_nodes, MIN_CHOICE_NODES),
        ("концовок", len(report.endings), MIN_ENDINGS),
    ]
    for label, actual, required in thresholds:
        mark = "ok" if actual >= required else "МАЛО"
        if actual < required:
            report.error(f"порог фазы 2: {label} {actual} < {required}")
        print(f"  порог {label:<18} {actual:>4} / нужно {required:<4} [{mark}]")

    print()
    if report.errors:
        print(f"ОШИБКИ ({len(report.errors)}):")
        for message in report.errors:
            print(f"  ! {message}")
    if report.warnings:
        print(f"ПРЕДУПРЕЖДЕНИЯ ({len(report.warnings)}):")
        for message in report.warnings:
            print(f"  ~ {message}")
    print()
    if report.errors:
        print(f"ИТОГ: FAIL — {len(report.errors)} ошибок, {len(report.warnings)} предупреждений")
        return 1
    print(f"ИТОГ: OK — ошибок нет, предупреждений {len(report.warnings)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
