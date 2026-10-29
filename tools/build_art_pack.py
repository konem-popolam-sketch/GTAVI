#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""build_art_pack.py — офлайн-сборка материалов и сцены пропсов из манифеста.

Запуск:  python tools\\build_art_pack.py
         python tools\\build_art_pack.py --apply-block            (заменить материалы в block.tscn)
         python tools\\build_art_pack.py --apply-block --apply-block-metal

Читает docs/art/asset_manifest.json (его пишет tools/fetch_art_assets.py) и создаёт:
  * assets/materials/<key>_pbr.tres — StandardMaterial3D: albedo_texture, normal (из nor_gl),
    roughness_texture, ao_texture, uv1_scale по размеру поверхности;
  * scenes/world/props.tscn — Node3D "Props" + 16 инстансов CC0-моделей, расставленных вручную;
  * assets/models/props/LICENSE.md — CC0-таблица;
  * docs/art/asset_manifest.md — человекочитаемая сводка (список файлов и лицензий).

Сеть не нужна. Существующие материалы с ДРУГИМИ именами не трогаются (старые .tres остаются
рабочими); --apply-block меняет только path в ext_resource block.tscn, не узлы и не коллизии.
"""

import argparse
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "docs", "art", "asset_manifest.json")
MAT_DIR = os.path.join(ROOT, "assets", "materials")
MODEL_DIR = os.path.join(ROOT, "assets", "models", "props")
SCENE_OUT = os.path.join(ROOT, "scenes", "world", "props.tscn")
BLOCK_SCENE = os.path.join(ROOT, "scenes", "world", "block.tscn")
ART_MD = os.path.join(ROOT, "docs", "art", "asset_manifest.md")


class BuildError(RuntimeError):
    pass


def log(msg):
    print("[build] " + str(msg), flush=True)


# Материалы: uv1_scale — количество повторов текстуры на грань (асфальт 8–16, кирпич 4–8);
# albedo — ночной множитель (текстуры сняты днём, сцена ночная, ACES).
MATERIALS = [
    {"key": "asphalt", "tex": "asphalt", "file": "asphalt_pbr.tres", "uv": 14.0,
     "albedo": (0.55, 0.57, 0.62), "metallic": 0.05, "specular": 0.5,
     "roughness": 0.95, "normal_scale": 0.9, "ao_light": 0.35},
    {"key": "brick_red", "tex": "brick", "file": "brick_red_pbr.tres", "uv": 6.0,
     "albedo": (0.86, 0.72, 0.66), "metallic": 0.0, "specular": 0.35,
     "roughness": 0.9, "normal_scale": 1.0, "ao_light": 0.4},
    {"key": "brick_grey", "tex": "brick", "file": "brick_grey_pbr.tres", "uv": 7.0,
     "albedo": (0.62, 0.68, 0.78), "metallic": 0.0, "specular": 0.35,
     "roughness": 0.9, "normal_scale": 1.0, "ao_light": 0.4},
    {"key": "concrete", "tex": "concrete", "file": "concrete_pbr.tres", "uv": 5.0,
     "albedo": (0.62, 0.65, 0.72), "metallic": 0.0, "specular": 0.3,
     "roughness": 0.95, "normal_scale": 0.8, "ao_light": 0.4},
    {"key": "plaster", "tex": "plaster", "file": "plaster_pbr.tres", "uv": 5.0,
     "albedo": (0.70, 0.68, 0.66), "metallic": 0.0, "specular": 0.3,
     "roughness": 0.93, "normal_scale": 0.7, "ao_light": 0.4},
    {"key": "metal", "tex": "metal", "file": "metal_pbr.tres", "uv": 3.0,
     "albedo": (0.60, 0.64, 0.72), "metallic": 0.75, "specular": 0.55,
     "roughness": 0.5, "normal_scale": 0.8, "ao_light": 0.3},
    {"key": "dock_planks", "tex": "dock_planks", "file": "dock_planks_pbr.tres", "uv": 6.0,
     "albedo": (0.62, 0.55, 0.48), "metallic": 0.0, "specular": 0.35,
     "roughness": 0.88, "normal_scale": 1.0, "ao_light": 0.4},
    {"key": "roof", "tex": "roof", "file": "roof_pbr.tres", "uv": 4.0,
     "albedo": (0.55, 0.57, 0.60), "metallic": 0.0, "specular": 0.3,
     "roughness": 0.92, "normal_scale": 0.9, "ao_light": 0.35},
]

# Расстановка по кварталу. Координаты сняты с scenes/world/block.tscn:
#   улица/площадь z 0..20, магазин (-4, 0, -10.9), переулок (4, 0, -11.6), пирс z≈34 (настил y=-0.7).
# Свободные коридоры (спавн→магазин, →переулок, →пирс) и NPC-слоты не перекрываются;
# у пропсов НЕТ коллизий, поэтому проходы не блокируются.
PROP_LAYOUT = [
    {"name": "TrashCanShop", "role": "trash_can", "x": 1.35, "y": 0.0, "z": -10.55, "ry": 0.0},
    {"name": "WetSignShop", "role": "wet_sign", "x": 0.2, "y": 0.0, "z": -11.4, "ry": 10.0},
    {"name": "BarrelPier", "role": "barrel", "x": 2.15, "y": -0.7, "z": 37.8, "ry": 20.0},
    {"name": "BarrelAlleyA", "role": "barrel", "x": 5.15, "y": 0.0, "z": -20.9, "ry": 20.0},
    {"name": "BarrelAlleyB", "role": "barrel", "x": 5.2, "y": 0.0, "z": -19.8, "ry": -12.0},
    {"name": "CrateAlleyA", "role": "crate_wood", "x": 2.45, "y": 0.0, "z": -16.4, "ry": 8.0},
    {"name": "CrateAlleyA_top", "role": "crate_wood", "x": 2.5, "y": 0.82, "z": -16.35,
     "ry": -6.0, "scale": 0.85},
    {"name": "CrateMilitaryAlley", "role": "crate_military", "x": 5.25, "y": 0.0, "z": -15.1,
     "ry": 15.0},
    {"name": "CratePlasticAlley", "role": "crate_plastic", "x": 4.95, "y": 0.0, "z": -13.2,
     "ry": -25.0},
    {"name": "TrashBagAlley", "role": "trashbag", "x": 2.5, "y": 0.0, "z": -23.2, "ry": 0.0},
    {"name": "PipesWallA", "role": "pipes", "x": 5.8, "y": 1.4, "z": -6.4, "ry": -90.0},
    {"name": "PipesWallB", "role": "pipes", "x": 5.8, "y": 1.4, "z": -2.0, "ry": -90.0},
    {"name": "LadderAlley", "role": "ladder", "x": 2.3, "y": 0.0, "z": -21.0, "ry": 90.0},
    {"name": "BenchSeafront", "role": "bench", "x": -6.6, "y": 0.0, "z": 20.3, "ry": 180.0},
    {"name": "CratePier", "role": "crate_wood", "x": 2.05, "y": -0.7, "z": 36.2, "ry": 25.0},
    {"name": "TrashCanPier", "role": "trash_can", "x": -2.15, "y": -0.7, "z": 28.0, "ry": 0.0},
]

BLOCK_SWAPS = {
    "res://assets/materials/asphalt.tres": "res://assets/materials/asphalt_pbr.tres",
    "res://assets/materials/brick.tres": "res://assets/materials/brick_red_pbr.tres",
    "res://assets/materials/concrete.tres": "res://assets/materials/concrete_pbr.tres",
    "res://assets/materials/dock_planks.tres": "res://assets/materials/dock_planks_pbr.tres",
}
BLOCK_SWAPS_OPTIONAL = {
    "res://assets/materials/metal.tres": "res://assets/materials/metal_pbr.tres",
}


def load_manifest():
    if not os.path.isfile(MANIFEST):
        raise BuildError("нет %s — сначала запусти tools\\fetch_art_assets.py"
                         % os.path.relpath(MANIFEST, ROOT))
    with open(MANIFEST, "r", encoding="utf-8") as fh:
        return json.load(fh)


def res_path(rel):
    return "res://" + rel.replace("\\", "/")


def write_material(mat, tex_set):
    files = tex_set["files"]
    ext = [("1_albedo", files["diff"]), ("2_normal", files["normal"]), ("3_rough", files["rough"])]
    if "ao" in files:
        ext.append(("4_ao", files["ao"]))
    lines = ['[gd_resource type="StandardMaterial3D" load_steps=%d format=3]' % (len(ext) + 1), ""]
    lines.append("; Сгенерировано tools/build_art_pack.py. Источник: Poly Haven, %s, CC0."
                 % tex_set.get("asset_id", "?"))
    lines.append("; PBR: albedo + normal (nor_gl) + roughness + AO; uv1_scale по размеру поверхности.")
    lines.append("")
    for ext_id, path in ext:
        lines.append('[ext_resource type="Texture2D" path="%s" id="%s"]' % (res_path(path), ext_id))
    lines.append("")
    lines.append("[resource]")
    lines.append('resource_name = "%s"' % mat["key"])
    lines.append('albedo_texture = ExtResource("1_albedo")')
    lines.append("albedo_color = Color(%.3f, %.3f, %.3f, 1)" % mat["albedo"])
    lines.append("metallic = %.2f" % mat["metallic"])
    lines.append("metallic_specular = %.2f" % mat["specular"])
    lines.append("roughness = %.2f" % mat["roughness"])
    lines.append('roughness_texture = ExtResource("3_rough")')
    lines.append("roughness_texture_channel = %d" % int(tex_set.get("rough_channel", 0)))
    lines.append("normal_enabled = true")
    lines.append('normal_texture = ExtResource("2_normal")')
    lines.append("normal_scale = %.2f" % mat["normal_scale"])
    if "ao" in files:
        lines.append("ao_enabled = true")
        lines.append('ao_texture = ExtResource("4_ao")')
        lines.append("ao_texture_channel = %d" % int(tex_set.get("ao_channel", 0)))
        lines.append("ao_light_affect = %.2f" % mat["ao_light"])
    lines.append("uv1_scale = Vector3(%.1f, %.1f, %.1f)" % (mat["uv"], mat["uv"], mat["uv"]))
    lines.append("")
    dest = os.path.join(MAT_DIR, mat["file"])
    os.makedirs(MAT_DIR, exist_ok=True)
    with open(dest, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    log("material %-22s ← %s (uv1_scale %.1f)" % (mat["file"], tex_set["asset_id"], mat["uv"]))
    return os.path.relpath(dest, ROOT).replace("\\", "/")


def write_props_scene(manifest):
    by_role = {}
    for item in manifest.get("models", []):
        by_role.setdefault(item["role"], item)
    missing = sorted({p["role"] for p in PROP_LAYOUT if p["role"] not in by_role})
    if missing:
        raise BuildError("в манифесте нет моделей для ролей: %s" % ", ".join(missing))
    for item in by_role.values():
        abs_path = os.path.join(ROOT, item["file"])
        if not os.path.isfile(abs_path):
            raise BuildError("файл модели отсутствует: %s" % item["file"])

    roles = []
    for item in PROP_LAYOUT:
        if item["role"] not in roles:
            roles.append(item["role"])
    res_ids = {}
    entries = []
    for index, role in enumerate(roles, start=1):
        res_id = "1%d_%s" % (index, role)
        res_ids[role] = res_id
        entries.append((res_id, by_role[role]["file"]))

    lines = ["[gd_scene load_steps=%d format=3]" % (len(entries) + 1), ""]
    lines.append("; Сгенерировано tools/build_art_pack.py — %d CC0-пропсов Poly Haven по кварталу."
                 % len(PROP_LAYOUT))
    lines.append("; Вставлять как дочерний узел Main (рядом с World): координаты мировые, коллизий нет.")
    lines.append("")
    for res_id, path in entries:
        lines.append('[ext_resource type="PackedScene" path="%s" id="%s"]' % (res_path(path), res_id))
    lines.append("")
    lines.append('[node name="Props" type="Node3D"]')
    lines.append("")
    for item in PROP_LAYOUT:
        lines.append('[node name="%s" parent="." instance=ExtResource("%s")]'
                     % (item["name"], res_ids[item["role"]]))
        lines.append("position = Vector3(%.2f, %.2f, %.2f)" % (item["x"], item["y"], item["z"]))
        if item.get("ry"):
            lines.append("rotation = Vector3(0, %.4f, 0)" % math.radians(item["ry"]))
        if item.get("scale"):
            s = float(item["scale"])
            lines.append("scale = Vector3(%.2f, %.2f, %.2f)" % (s, s, s))
        lines.append("")
    os.makedirs(os.path.dirname(SCENE_OUT), exist_ok=True)
    with open(SCENE_OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    log("scene    scenes/world/props.tscn — %d экземпляров, %d моделей"
        % (len(PROP_LAYOUT), len(entries)))
    return len(PROP_LAYOUT)


def write_license(manifest):
    os.makedirs(MODEL_DIR, exist_ok=True)
    lines = ["# CC0-ассеты «Ночной смены» (Poly Haven)", ""]
    lines.append("Источник: [Poly Haven](https://polyhaven.com/) · лицензия **CC0 1.0** — "
                 "https://polyhaven.com/license")
    lines.append("Атрибуция не требуется; таблицы ниже — трассировка происхождения файлов.")
    lines.append("")
    lines.append("## Модели — assets/models/props/")
    lines.append("")
    lines.append("| id | Роль | Страница | Лицензия |")
    lines.append("| --- | --- | --- | --- |")
    for item in sorted(manifest.get("models", []), key=lambda m: m["asset_id"]):
        lines.append("| %s | %s | https://polyhaven.com/a/%s | CC0 |"
                     % (item["asset_id"], item["role"], item["asset_id"]))
    lines.append("")
    lines.append("## Текстуры — assets/textures/")
    lines.append("")
    lines.append("| Набор | id | Страница | Лицензия |")
    lines.append("| --- | --- | --- | --- |")
    for item in manifest.get("texture_sets", []):
        lines.append("| %s | %s | https://polyhaven.com/a/%s | CC0 |"
                     % (item["key"], item["asset_id"], item["asset_id"]))
    lines.append("")
    lines.append("Карты переименованы в `_diff`, `_normal`, `_rough`, `_ao`: импортёр Godot 4 по этим")
    lines.append("суффиксам сам выбирает sRGB/linear и тип normal map. Размер — только 2k (модели 1k).")
    lines.append("")
    with open(os.path.join(MODEL_DIR, "LICENSE.md"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    log("license  assets/models/props/LICENSE.md")


def write_manifest_md(manifest, materials, scene_count):
    os.makedirs(os.path.dirname(ART_MD), exist_ok=True)
    lines = ["# Сводка пака реализма (сгенерировано build_art_pack.py)", ""]
    lines.append("Скачано: %s · всего %.1f MB · текстурных наборов %d · моделей %d"
                 % (manifest.get("generated_at", "?"),
                    manifest.get("stats", {}).get("download_mb", 0.0),
                    len(manifest.get("texture_sets", [])),
                    len(manifest.get("models", []))))
    lines.append("")
    lines.append("## Материалы → файлы → где применены")
    lines.append("")
    lines.append("| Материал | .tres | Текстуры | uv1_scale | Где применён |")
    lines.append("| --- | --- | --- | --- | --- |")
    usage = {
        "asphalt": "Ground (block.tscn), дорожное покрытие",
        "brick_red": "BuildingA, стены магазина",
        "brick_grey": "тот же кирпич с холодным тоном — резерв для построек level-designer",
        "concrete": "BuildingB, парапеты Perimeter, Alley/BackWall, Slope",
        "plaster": "резерв: задние стены, крыша магазина",
        "metal": "двери, ставни, ограждения (опционально)",
        "dock_planks": "PierDeck, Alley/Crate",
        "roof": "крыши/рубероид (резерв)",
    }
    for item in materials:
        mat_id = item["key"]
        lines.append("| %s | `%s` | `assets/textures/%s/` | %.1f | %s |"
                     % (mat_id, item["file"], item["tex"], item["uv"],
                        usage.get(mat_id, "—")))
    lines.append("")
    lines.append("## Пропсы → где стоят")
    lines.append("")
    lines.append("| Узел | Роль | Модель | Позиция |")
    lines.append("| --- | --- | --- | --- |")
    by_role = {m["role"]: m["asset_id"] for m in manifest.get("models", [])}
    for item in PROP_LAYOUT:
        lines.append("| %s | %s | %s | (%.2f, %.2f, %.2f) |"
                     % (item["name"], item["role"], by_role.get(item["role"], "—"),
                        item["x"], item["y"], item["z"]))
    lines.append("")
    lines.append("Всего экземпляров: %d." % scene_count)
    lines.append("")
    with open(ART_MD, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    log("report   docs/art/asset_manifest.md")


def apply_block_swap(optional_metal=False):
    if not os.path.isfile(BLOCK_SCENE):
        raise BuildError("нет scenes/world/block.tscn")
    with open(BLOCK_SCENE, "r", encoding="utf-8") as fh:
        text = fh.read()
    swaps = dict(BLOCK_SWAPS)
    if optional_metal:
        swaps.update(BLOCK_SWAPS_OPTIONAL)
    changed = 0
    backup = os.path.join(ROOT, "tools", "block_pre_pbr.tscn.bak")
    for old, new in swaps.items():
        if old in text:
            if not os.path.isfile(backup):
                with open(backup, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(text)
            text = text.replace(old, new)
            changed += 1
            log("swap     %s → %s" % (os.path.basename(old), os.path.basename(new)))
    if changed:
        with open(BLOCK_SCENE, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        log("block.tscn: заменено %d материалов, бэкап tools/block_pre_pbr.tscn.bak" % changed)
    else:
        log("block.tscn: менять нечего")


def run(apply_block=False, apply_block_metal=False):
    manifest = load_manifest()
    tex_by_key = {item["key"]: item for item in manifest.get("texture_sets", [])}

    materials = []
    for mat in MATERIALS:
        tex_set = tex_by_key.get(mat["tex"])
        if tex_set is None:
            log("skip     материал %s: нет набора '%s'" % (mat["file"], mat["tex"]))
            continue
        for logical in ("diff", "normal", "rough"):
            if logical not in tex_set["files"]:
                raise BuildError("в наборе '%s' нет карты '%s'" % (mat["tex"], logical))
        path = write_material(mat, tex_set)
        materials.append({"key": mat["key"], "file": path, "tex": mat["tex"],
                          "uv": mat["uv"], "textures": tex_set["asset_id"]})
    if len(materials) < 6:
        raise BuildError("материалов меньше 6: %d" % len(materials))

    scene_count = write_props_scene(manifest)
    write_license(manifest)
    write_manifest_md(manifest, materials, scene_count)
    if apply_block:
        apply_block_swap(optional_metal=apply_block_metal)
    log("готово: материалов %d, пропсов %d" % (len(materials), scene_count))
    return 0


def main():
    parser = argparse.ArgumentParser(description="Собрать материалы и props.tscn из манифеста")
    parser.add_argument("--apply-block", action="store_true",
                        help="заменить материалы в scenes/world/block.tscn (только path ext_resource)")
    parser.add_argument("--apply-block-metal", action="store_true",
                        help="с --apply-block менять и metal.tres (проверить кадр: металл может потемнеть)")
    args = parser.parse_args()
    try:
        return run(apply_block=args.apply_block, apply_block_metal=args.apply_block_metal)
    except BuildError as exc:
        log("FAILED: %s" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
