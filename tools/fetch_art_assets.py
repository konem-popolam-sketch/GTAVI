#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fetch_art_assets.py — скачивание CC0-ассетов Poly Haven для «Ночной смены».

Запуск:  python tools\\fetch_art_assets.py
         python tools\\fetch_art_assets.py --dry-run

Правила:
  * только проверенные id + жёсткая валидация: у набора должны быть Diffuse + nor_gl + Rough
    (AO желателен); иначе берётся следующий кандидат из списка, потом keyword-фолбэк;
  * только 2k-текстуры и glTF 1k-модели, только отдельные файлы, никаких архивов и 8k;
  * id сравниваются case-insensitive (в Poly Haven есть legacy id вида `WetFloorSign_01`);
  * повторный запуск докачивает недостающее, готовые файлы не перезаписывает.

Результат: assets/textures/<asset_id>/…, assets/models/props/<asset_id>/…,
docs/art/asset_manifest.json (его читает tools/build_art_pack.py).
"""

import argparse
import datetime
import json
import os
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEX_DIR = os.path.join(ROOT, "assets", "textures")
MODEL_DIR = os.path.join(ROOT, "assets", "models", "props")
ART_DOC_DIR = os.path.join(ROOT, "docs", "art")
MANIFEST = os.path.join(ART_DOC_DIR, "asset_manifest.json")

API = "https://api.polyhaven.com"
UA = "night-shift-art-pack/1.0 (Godot 4.7.2; CC0 asset fetch)"
SIZE = "2k"

FILES_CACHE = {}


class ArtPackError(RuntimeError):
    pass


def log(msg):
    print("[art] " + str(msg), flush=True)


# ------------------------------------------------------------------------ сеть

def http_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def download(url, dest, retries=3):
    """Скачать url в dest. Уже скачанный непустой файл не трогаем."""
    if os.path.isfile(dest) and os.path.getsize(dest) > 1024:
        log("skip  %s" % os.path.relpath(dest, ROOT))
        return os.path.getsize(dest)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    last_error = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=180) as resp:
                data = resp.read()
            if len(data) < 1024:
                raise IOError("подозрительно маленький ответ: %d байт" % len(data))
            tmp = dest + ".part"
            with open(tmp, "wb") as fh:
                fh.write(data)
            os.replace(tmp, dest)
            log("ok    %-62s %6.1f MB" % (os.path.relpath(dest, ROOT), len(data) / 1048576.0))
            return len(data)
        except Exception as exc:  # noqa: BLE001 — сеть падает чем угодно
            last_error = exc
            log("retry %d/%d %s: %s" % (attempt, retries, type(exc).__name__, exc))
            time.sleep(1.5 * attempt)
    raise ArtPackError("не скачалось %s (%s)" % (url, last_error))


def files_of(asset_id):
    if asset_id not in FILES_CACHE:
        try:
            FILES_CACHE[asset_id] = http_json(API + "/files/" + asset_id)
        except Exception:
            FILES_CACHE[asset_id] = None
    return FILES_CACHE[asset_id]


def asset_index(kind):
    data = http_json(API + "/assets?t=" + kind)
    if not isinstance(data, dict) or not data:
        raise ArtPackError("пустой список ассетов Poly Haven (%s)" % kind)
    return data


def lower_map(index):
    return {str(asset_id).lower(): asset_id for asset_id in index}


def haystack(asset_id, meta):
    parts = [asset_id, str(meta.get("name", ""))]
    parts += [str(x) for x in (meta.get("tags") or [])]
    parts += [str(x) for x in (meta.get("categories") or [])]
    return " ".join(parts).lower()


def keyword_pick(assets, include, exclude=(), require=None):
    scored = []
    for asset_id, meta in assets.items():
        hay = haystack(asset_id, meta)
        if any(bad.lower() in hay for bad in exclude):
            continue
        score = sum(1 for kw in include if kw.lower() in hay)
        if score:
            scored.append((score, asset_id))
    scored.sort(key=lambda item: (-item[0], item[1]))
    for _, asset_id in scored:
        if require is None or require(asset_id):
            return asset_id
    return None


# ----------------------------------------------------------------------- конфиг

# 7 наборов текстур: id проверены капитаном (у всех есть Diffuse + nor_gl + Rough + AO).
TEXTURE_SETS = [
    {"key": "asphalt", "ids": ["asphalt_01", "asphalt_03", "asphalt_05"],
     "include": ["asphalt", "road"], "exclude": ["wet", "puddle", "snow", "tile"]},
    {"key": "brick", "ids": ["brick_4", "brick_crosswalk", "brick_floor_003"],
     "include": ["brick"], "exclude": ["white", "paint"]},
    {"key": "concrete", "ids": ["concrete_wall_008", "concrete_wall_004", "brushed_concrete",
                                "brushed_concrete_03", "anti_slip_concrete"],
     "include": ["concrete"], "exclude": ["polished", "ceiling"]},
    {"key": "plaster", "ids": ["beige_wall_001", "blue_plaster_wall", "clay_plaster",
                               "damaged_plaster"],
     "include": ["plaster", "stucco"], "exclude": ["brick", "concrete", "wood", "tile"]},
    {"key": "metal", "ids": ["metal_plate_02", "metal_plate", "corrugated_iron_02",
                             "blue_metal_plate", "box_profile_metal_sheet"],
     "include": ["metal", "steel", "corrugated"], "exclude": ["gold", "copper", "brass"]},
    {"key": "dock_planks", "ids": ["brown_planks_03", "brown_planks_04", "wood_planks",
                                   "plank_flooring_02"],
     "include": ["planks", "plank"], "exclude": ["parquet", "furniture", "tile"]},
    {"key": "roof", "ids": ["ceramic_roof_01", "clay_roof_tiles", "clay_roof_tiles_02"],
     "include": ["roof", "shingle", "tile"], "exclude": ["terracotta", "thatch"]},
]

# 10 ролей пропсов — id из проверенных капитаном (16 инстансов в сцене).
PROP_ROLES = [
    {"role": "trash_can", "ids": ["metal_trash_can"],
     "include": ["trash can", "trashcan", "trash bin", "dumpster"], "exclude": ["bag"]},
    {"role": "crate_wood", "ids": ["wooden_crate_01", "wooden_crate_02"],
     "include": ["wooden crate", "crate"], "exclude": ["plastic", "military"]},
    {"role": "crate_military", "ids": ["old_military_crate"],
     "include": ["military crate", "crate"], "exclude": ["plastic"]},
    {"role": "crate_plastic", "ids": ["plastic_crate_01", "plastic_crate_02", "plastic_crate_03"],
     "include": ["plastic crate"], "exclude": []},
    {"role": "barrel", "ids": ["barrel_01", "barrel_02", "barrel_03"],
     "include": ["barrel", "drum"], "exclude": []},
    {"role": "bench", "ids": ["painted_wooden_bench", "bench_vice_01"],
     "include": ["bench"], "exclude": ["vice"]},
    {"role": "pipes", "ids": ["modular_industrial_pipes_01", "modular_pipes"],
     "include": ["pipe", "duct", "vent"], "exclude": []},
    {"role": "ladder", "ids": ["wooden_ladder", "ladder_sectioned_01"],
     "include": ["ladder"], "exclude": []},
    {"role": "wet_sign", "ids": ["WetFloorSign_01", "wetfloorsign_01", "wet_floor_sign_01"],
     "include": ["wet floor", "caution sign"], "exclude": []},
    {"role": "trashbag", "ids": ["trashbag", "trash_bag"],
     "include": ["trash bag", "trashbag", "garbage bag"], "exclude": []},
]


# ------------------------------------------------------------------ текстуры

def map_entry(block, names):
    lower = {str(key).lower(): key for key in block}
    for name in names:
        key = lower.get(name.lower())
        if key is not None:
            return block[key]
    return None


def texture_plan(asset_id):
    """План скачивания набора: формат/размер/карты. None, если карт не хватает.

    The Poly Haven /files/<id> payload is keyed by MAP first, then by size, then
    by image format: {"Diffuse": {"2k": {"jpg": {"url": ...}}, ...}, ...}.
    Walking it in the other order (format -> size -> map) never matches, which is
    why every set used to be reported as having no maps.
    """
    files = files_of(asset_id) or {}
    if not isinstance(files, dict):
        return None

    def pick(names, size_key, fmt):
        for name in names:
            node = files.get(name)
            if not isinstance(node, dict):
                continue
            block = node.get(size_key)
            if not isinstance(block, dict):
                continue
            entry = block.get(fmt)
            if isinstance(entry, dict) and "url" in entry:
                return entry
        return None

    diffuse_names = ["Diffuse", "diffuse", "diff", "albedo", "Color"]
    normal_names = ["nor_gl", "Normal", "normal", "nor_dx"]
    rough_names = ["Rough", "rough", "roughness", "Gloss"]
    ao_names = ["AO", "ao", "ambient_occlusion", "occlusion"]
    arm_names = ["arm", "ao_rough_metal", "orm", "Arm"]

    for size_key in ("2k", "1k"):
        for fmt in ("jpg", "png"):
            diff = pick(diffuse_names, size_key, fmt)
            normal = pick(normal_names, size_key, fmt)
            rough = pick(rough_names, size_key, fmt)
            ao = pick(ao_names, size_key, fmt)
            arm = pick(arm_names, size_key, fmt)
            rough_channel = 0
            ao_channel = 0
            if rough is None and arm is not None:
                rough = arm
                rough_channel = 1
            if ao is None and arm is not None:
                ao = arm
                ao_channel = 0
            if not (isinstance(diff, dict) and isinstance(normal, dict) and isinstance(rough, dict)):
                continue
            return {"fmt": fmt, "size": size_key, "diff": diff, "normal": normal,
                    "rough": rough, "ao": ao, "rough_channel": rough_channel,
                    "ao_channel": ao_channel}
    return None


def resolve_texture(spec, textures, lower_textures):
    for asset_id in spec.get("ids", []):
        real = lower_textures.get(asset_id.lower(), asset_id)
        if texture_plan(real) is not None:
            return real
        log("skip  '%s': нет полного набора карт" % asset_id)
    asset_id = keyword_pick(textures, spec["include"], spec.get("exclude", ()),
                            require=lambda aid: texture_plan(aid) is not None)
    if not asset_id:
        raise ArtPackError("не нашёл валидную текстуру для набора '%s'" % spec["key"])
    return asset_id


def fetch_texture_set(spec, textures, lower_textures, dry_run):
    asset_id = resolve_texture(spec, textures, lower_textures)
    plan = texture_plan(asset_id)
    if plan is None:
        raise ArtPackError("у '%s' нет карт" % asset_id)
    size_key = plan["size"]
    ext = plan["fmt"]
    if size_key != SIZE:
        log("warn  '%s': нет %s, беру %s" % (asset_id, SIZE, size_key))
    out_dir = os.path.join(TEX_DIR, asset_id)

    result = {"key": spec["key"], "asset_id": asset_id, "size": size_key,
              "source": "https://polyhaven.com/a/" + asset_id, "license": "CC0",
              "files": {}, "rough_channel": int(plan["rough_channel"]),
              "ao_channel": int(plan["ao_channel"]), "bytes": 0}

    for logical in ("diff", "normal", "rough", "ao"):
        entry = plan.get(logical)
        if not isinstance(entry, dict) or "url" not in entry:
            if logical == "ao":
                log("note  '%s': AO нет — материал будет без AO" % asset_id)
                continue
            raise ArtPackError("у '%s' нет карты '%s'" % (asset_id, logical))
        fname = "%s_%s_%s.%s" % (asset_id, logical, size_key, ext)
        dest = os.path.join(out_dir, fname)
        if not dry_run:
            result["bytes"] += download(entry["url"], dest)
        result["files"][logical] = os.path.relpath(dest, ROOT).replace("\\", "/")
    log("set   %-12s ← %-28s %s (%d карт)" % (spec["key"], asset_id, size_key,
                                              len(result["files"])))
    return result


# -------------------------------------------------------------------- модели

def model_plan(asset_id):
    files = files_of(asset_id) or {}
    return (files.get("gltf") or {}).get("1k") or None


def fallback_prop(models, used):
    all_keywords = []
    for spec in PROP_ROLES:
        all_keywords += [kw for kw in spec.get("include", []) if kw not in all_keywords]

    def usable(asset_id):
        return asset_id not in used and model_plan(asset_id) is not None

    asset_id = keyword_pick(models, all_keywords, (), require=usable)
    if asset_id:
        return asset_id
    for asset_id in sorted(models):
        if usable(asset_id):
            return asset_id
    return None


def resolve_prop(role_spec, models, lower_models, used):
    for asset_id in role_spec.get("ids", []):
        real = lower_models.get(asset_id.lower(), asset_id)
        if model_plan(real) is not None:
            return real
        log("skip  модель '%s' (роль %s): нет glTF 1k" % (asset_id, role_spec["role"]))
    asset_id = keyword_pick(models, role_spec["include"], role_spec.get("exclude", ()),
                            require=lambda aid: aid not in used and model_plan(aid) is not None)
    if not asset_id:
        raise ArtPackError("не нашёл модель для роли '%s'" % role_spec["role"])
    return asset_id


def fetch_model(asset_id, role, dry_run):
    block = model_plan(asset_id)
    if not block:
        raise ArtPackError("у модели '%s' нет glTF 1k" % asset_id)
    out_dir = os.path.join(MODEL_DIR, asset_id)
    jobs = []
    gltf_name = None
    for key, value in block.items():
        if isinstance(value, dict) and "url" in value:
            name = os.path.basename(value["url"].split("?")[0])
            jobs.append((value["url"], name))
            if key == "gltf":
                gltf_name = name
        elif isinstance(value, dict):
            for rel, meta in value.items():
                if isinstance(meta, dict) and "url" in meta:
                    jobs.append((meta["url"], rel))
    if gltf_name is None:
        raise ArtPackError("у '%s' нет файла .gltf" % asset_id)
    total = 0
    if not dry_run:
        for url, name in jobs:
            total += download(url, os.path.join(out_dir, name.replace("/", os.sep)))
    log("model %-14s ← %-30s %s (1k, %d файлов)" % (role, asset_id, gltf_name, len(jobs)))
    return {
        "role": role,
        "asset_id": asset_id,
        "file": os.path.relpath(os.path.join(out_dir, gltf_name), ROOT).replace("\\", "/"),
        "source": "https://polyhaven.com/a/" + asset_id,
        "license": "CC0",
        "bytes": total,
    }


# ---------------------------------------------------------------------- main

def run(dry_run=False):
    os.makedirs(TEX_DIR, exist_ok=True)
    os.makedirs(MODEL_DIR, exist_ok=True)
    os.makedirs(ART_DOC_DIR, exist_ok=True)

    log("Poly Haven CC0: текстуры %s, модели glTF 1k" % SIZE)
    textures = asset_index("textures")
    models = asset_index("models")
    lower_textures = lower_map(textures)
    lower_models = lower_map(models)
    log("API: textures=%d, models=%d" % (len(textures), len(models)))

    texture_sets = [fetch_texture_set(spec, textures, lower_textures, dry_run)
                    for spec in TEXTURE_SETS]
    if len(texture_sets) < 6:
        raise ArtPackError("наборов текстур меньше 6: %d" % len(texture_sets))

    records = []
    used = set()
    for role_spec in PROP_ROLES:
        role = role_spec["role"]
        try:
            asset_id = resolve_prop(role_spec, models, lower_models, used)
        except ArtPackError as exc:
            fallback = fallback_prop(models, used)
            if not fallback:
                raise
            log("warn  роль '%s': %s — беру '%s'" % (role, exc, fallback))
            asset_id = fallback
        if asset_id in used:
            log("note  модель '%s' уже занята другой ролью" % asset_id)
        used.add(asset_id)
        records.append(fetch_model(asset_id, role, dry_run))
    if len(records) < 8:
        raise ArtPackError("пропсов меньше 8: %d" % len(records))

    if not dry_run:
        for item in records:
            if not os.path.isfile(os.path.join(ROOT, item["file"])):
                raise ArtPackError("файл модели не появился: %s" % item["file"])

    total_bytes = sum(t.get("bytes", 0) for t in texture_sets) + sum(m.get("bytes", 0) for m in records)
    manifest = {
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "license": "CC0 (Poly Haven) — https://polyhaven.com/license",
        "texture_size": SIZE,
        "texture_sets": texture_sets,
        "models": records,
        "stats": {"download_bytes": total_bytes,
                  "download_mb": round(total_bytes / 1048576.0, 1),
                  "texture_sets": len(texture_sets), "models": len(records)},
    }
    if not dry_run:
        with open(MANIFEST, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(manifest, fh, ensure_ascii=False, indent=2)

    log("---- сводка ----")
    for item in texture_sets:
        log("tex %-12s %-28s %-4s карты: %s" % (item["key"], item["asset_id"], item["size"],
                                                ", ".join(sorted(item["files"]))))
    for item in records:
        log("mdl %-14s %-30s" % (item["role"], item["asset_id"]))
    log("итого: %d наборов текстур, %d моделей, %.1f MB"
        % (len(texture_sets), len(records), total_bytes / 1048576.0))
    if not dry_run:
        log("manifest: %s" % os.path.relpath(MANIFEST, ROOT))
    return manifest


def main():
    parser = argparse.ArgumentParser(description="Скачать CC0-ассеты Poly Haven")
    parser.add_argument("--dry-run", action="store_true", help="только выбрать id, не качать")
    args = parser.parse_args()
    try:
        run(dry_run=args.dry_run)
    except ArtPackError as exc:
        log("FAILED: %s" % exc)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
