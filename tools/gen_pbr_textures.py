#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_pbr_textures.py — процедурные тайлящиеся PBR-текстуры для «Ночной смены».

Почему процедурно: CDN Poly Haven / ambientCG в этой сети не отдаются (см. docs/art/README.md).
Генератор ни от чего не зависит, лицензий нет вообще (всё своё), 2k, полный PBR-набор.

Запуск:  python tools\\gen_pbr_textures.py
         python tools\\gen_pbr_textures.py --size 1024        (быстрая проверка)
         python tools\\gen_pbr_textures.py --only brick,metal

Создаёт на каждый набор (7):
  assets/textures/<key>/<key>_diff_2k.png     albedo (sRGB-цвет)
  assets/textures/<key>/<key>_normal_2k.png   normal map (OpenGL/Godot: G-канал «вверх»)
  assets/textures/<key>/<key>_rough_2k.png    roughness (серый)
  assets/textures/<key>/<key>_ao_2k.png       ambient occlusion (серый)

И материалы Godot:
  assets/materials/{asphalt,brick_red,brick_grey,concrete,plaster,metal,dock_planks,roof}_pbr.tres
  assets/materials/prop_{wood_olive,plastic,sign_white,bag_dark,rust}.tres

Плюс docs/art/pbr_manifest.json — параметры генерации и список файлов (для отчёта QA).
Тайлинг гарантирован: весь шум генерируется фильтрацией в частотной области (периодическая
сетка), кладка/доски/черепица считаются по дробным координатам с целыми периодами.
"""

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEX_DIR = os.path.join(ROOT, "assets", "textures")
MAT_DIR = os.path.join(ROOT, "assets", "materials")
ART_DIR = os.path.join(ROOT, "docs", "art")
MANIFEST = os.path.join(ART_DIR, "pbr_manifest.json")

DEFAULT_SIZE = 2048
DEFAULT_SEED = 20261026


# ------------------------------------------------------------------ математика

def _grid(size):
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    return x / float(size), y / float(size)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / max(e1 - e0, 1e-9), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def fbm(size, freq, rng, sx=1.0, sy=1.0, octaves=5, gain=0.55, lacunarity=2.0):
    """Периодический fBm: фильтрация белого шума в Фурье (сетка частот замкнута).

    sx/sy — анизотропия фильтра: sx<1 убирает мелкие детали по X (поток вдоль X),
    sy>1 оставляет мелкие детали по Y. Возврат: mean≈0, std≈1, форма (size,size).
    """
    fy = np.fft.fftfreq(size).astype(np.float32).reshape(-1, 1)
    fx = np.fft.fftfreq(size).astype(np.float32).reshape(1, -1)
    out = np.zeros((size, size), np.float32)
    amp = 1.0
    total = 0.0
    f = float(freq)
    for _ in range(octaves):
        white = rng.standard_normal((size, size)).astype(np.float32)
        filt = np.exp(-((fx / (f * sx)) ** 2 + (fy / (f * sy)) ** 2))
        layer = np.fft.ifft2(np.fft.fft2(white) * filt).real.astype(np.float32)
        std = float(layer.std())
        if std < 1e-9:
            std = 1.0
        out += (amp / std) * layer
        total += amp
        amp *= gain
        f *= lacunarity
    out /= max(total, 1e-9)
    std = float(out.std())
    return out / (std if std > 1e-9 else 1.0)


def blur(size, arr, sigma_px):
    """Гауссово размытие через Фурье (периодическое, без краевых эффектов)."""
    fy = np.fft.fftfreq(size).astype(np.float32).reshape(-1, 1)
    fx = np.fft.fftfreq(size).astype(np.float32).reshape(1, -1)
    g = np.exp(-2.0 * (np.pi ** 2) * (sigma_px ** 2) * (fx ** 2 + fy ** 2))
    return np.fft.ifft2(np.fft.fft2(arr) * g).real.astype(np.float32)


def hash01(a, b):
    """Детерминированный псевдослучайный 0..1 из целочисленных индексов (тайлится)."""
    h = np.sin(a * 12.9898 + b * 78.233) * 43758.5453
    return (h - np.floor(h)).astype(np.float32)


def lerp(a, b, t):
    return a + (b - a) * t


def rgb(r, g, b, size):
    return np.dstack([np.full((size, size), r, np.float32),
                      np.full((size, size), g, np.float32),
                      np.full((size, size), b, np.float32)])


def mix_rgb(a, b, t):
    t = t[..., None] if t.ndim == 2 else t
    return a * (1.0 - t) + b * t


def normal_from_height(size, height, strength):
    """OpenGL/Godot normal map: G-канал смотрит «вверх» (флип относительно DirectX)."""
    gx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5
    gy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5
    sx = float(gx.std()) or 1.0
    sy = float(gy.std()) or 1.0
    nx = -(gx / sx) * strength
    ny = (gy / sy) * strength          # <-- флип G для Godot/OpenGL
    nz = np.ones_like(height)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    out = np.dstack([nx * inv, ny * inv, nz * inv]) * 0.5 + 0.5
    return out


def ao_from_height(size, height, strength=1.0, radius=0.05):
    """AO из высоты: затемняем локальные впадины относительно размытой копии."""
    sigma = max(1.0, size * radius)
    blurred = blur(size, height, sigma)
    diff = np.maximum(0.0, blurred - height)
    scale = float(np.percentile(diff, 99.0)) or 1.0
    occ = np.clip(diff / scale, 0.0, 1.0)
    return np.clip(1.0 - strength * occ, 0.0, 1.0)


# --------------------------------------------------------------------- наборы

def gen_asphalt(size, rng):
    x, y = _grid(size)
    aggregate = fbm(size, 0.22, rng, octaves=4, gain=0.6)
    fine = fbm(size, 0.5, rng, octaves=3)
    patches = fbm(size, 0.006, rng, octaves=4)
    ridged = np.abs(fbm(size, 0.02, rng, octaves=5))
    cracks = smoothstep(0.055, 0.0, ridged)
    stones = smoothstep(0.55, 1.15, aggregate * 0.7 + fine * 0.45)

    height = 0.45 + 0.16 * stones + 0.07 * fine - 0.10 * cracks + 0.03 * patches
    base = 0.20 + 0.055 * patches + 0.10 * stones + 0.025 * fine
    albedo = np.dstack([base * 0.96, base * 0.98, base * 1.03])
    albedo *= (1.0 - 0.55 * cracks)[..., None]

    wet = smoothstep(0.35, 0.95, fbm(size, 0.008, rng, octaves=4))
    # Шероховатость намеренно СПОКОЙНАЯ: широкие мягкие пятна ±0.05, без контрастных
    # «луж масла» (жалоба капитана по кадру 10_spawn_phase2). Мокрость — намёком.
    rough = np.clip(0.84 - 0.07 * wet - 0.03 * stones + 0.02 * fine, 0.62, 0.95)
    return {"height": height, "albedo": albedo, "rough": rough,
            "normal_strength": 1.3, "ao_strength": 0.9, "ao_radius": 0.05,
            "uv": 20.0, "metallic": 0.02, "tint": (0.62, 0.64, 0.70)}


def gen_brick(size, rng):
    x, y = _grid(size)
    cols, rows = 8, 24
    row = np.floor(y * rows).astype(np.int32)
    offset = (row % 2) * 0.5
    u = (x + offset) * cols
    col = np.floor(u).astype(np.int32)
    fu = u - col
    fv = y * rows - row
    du = np.minimum(fu, 1.0 - fu) / cols
    dv = np.minimum(fv, 1.0 - fv) / rows
    mortar = 1.0 - smoothstep(0.0, 0.0045, np.minimum(du, dv))

    var = hash01(col.astype(np.float32), row.astype(np.float32))
    grain = fbm(size, 0.35, rng, octaves=4)
    chips = fbm(size, 0.09, rng, octaves=4)

    height = (0.78 * (1.0 - mortar) + 0.06 * grain + 0.05 * chips
              - 0.35 * mortar + 0.05 * (var - 0.5))
    base = mix_rgb(np.dstack([0.30, 0.12, 0.095]) * (0.80 + 0.35 * var[..., None]),
                   np.full((size, size, 3), 0.34, np.float32), mortar)
    base *= (0.85 + 0.18 * grain)[..., None]
    base *= (0.95 + 0.10 * chips)[..., None]
    rough = np.clip(0.86 + 0.10 * mortar + 0.05 * grain, 0.5, 1.0)
    return {"height": height, "albedo": base, "rough": rough,
            "normal_strength": 2.4, "ao_strength": 1.4, "ao_radius": 0.02,
            "uv": 6.0, "metallic": 0.0, "tint": (0.88, 0.74, 0.70)}


def gen_concrete(size, rng):
    x, y = _grid(size)
    mottle = fbm(size, 0.012, rng, octaves=5)
    fine = fbm(size, 0.30, rng, octaves=3)
    pits_n = fbm(size, 0.16, rng, octaves=2)
    pits = smoothstep(1.05, 1.6, pits_n)
    stains = fbm(size, 0.005, rng, octaves=4)

    height = 0.55 + 0.12 * mottle + 0.04 * fine - 0.18 * pits
    base = 0.42 + 0.06 * mottle + 0.03 * fine - 0.12 * pits - 0.05 * np.clip(stains, 0, 1)
    albedo = np.dstack([base * 0.97, base * 0.99, base * 1.05])
    rough = np.clip(0.90 + 0.06 * fine + 0.05 * pits, 0.4, 1.0)
    return {"height": height, "albedo": albedo, "rough": rough,
            "normal_strength": 1.1, "ao_strength": 1.0, "ao_radius": 0.04,
            "uv": 5.0, "metallic": 0.0, "tint": (0.70, 0.73, 0.80)}


def gen_plaster(size, rng):
    x, y = _grid(size)
    swirl = fbm(size, 0.02, rng, octaves=4)
    fine = fbm(size, 0.42, rng, octaves=3)
    ridged = np.abs(fbm(size, 0.03, rng, octaves=5))
    cracks = smoothstep(0.045, 0.0, ridged)
    stains = smoothstep(0.2, 1.0, fbm(size, 0.01, rng, octaves=3))

    height = 0.55 + 0.10 * swirl + 0.05 * fine - 0.12 * cracks
    base = 0.58 + 0.05 * swirl + 0.02 * fine - 0.10 * cracks - 0.06 * stains
    albedo = np.dstack([base * 1.01, base, base * 0.96])
    rough = np.clip(0.92 + 0.05 * fine - 0.03 * swirl, 0.4, 1.0)
    return {"height": height, "albedo": albedo, "rough": rough,
            "normal_strength": 1.0, "ao_strength": 0.9, "ao_radius": 0.03,
            "uv": 5.0, "metallic": 0.0, "tint": (0.74, 0.72, 0.70)}


def gen_metal(size, rng):
    x, y = _grid(size)
    brushed = fbm(size, 0.55, rng, sx=0.22, sy=1.8, octaves=4, gain=0.6)
    broad = fbm(size, 0.02, rng, octaves=3)
    rust_n = fbm(size, 0.035, rng, octaves=4)
    rust = smoothstep(0.75, 1.25, rust_n)

    # 2x2 панель: швы по осям + заклёпки около швов
    seam = np.zeros((size, size), np.float32)
    for axis in (x, y):
        d = np.minimum(np.abs(axis - 0.5), np.minimum(axis, 1.0 - axis))
        seam = np.maximum(seam, smoothstep(0.0035, 0.0, d))
    rivet = np.zeros((size, size), np.float32)
    for cx, cy in ((0.0, 0.0), (0.5, 0.0), (0.0, 0.5), (0.5, 0.5)):
        dx = np.abs(((x - cx + 0.5) % 1.0) - 0.5)
        dy = np.abs(((y - cy + 0.5) % 1.0) - 0.5)
        # ближайшая точка на шве: заклёпки вдоль линий x=cx и y=cy
        rivet = np.maximum(rivet, smoothstep(0.011, 0.006, np.sqrt((dx - 0.0) ** 2 + (dy - 0.0) ** 2)))

    height = 0.55 + 0.05 * brushed + 0.03 * broad - 0.20 * seam + 0.16 * rivet - 0.08 * rust
    base = 0.44 + 0.05 * brushed + 0.03 * broad - 0.16 * seam + 0.08 * rivet
    albedo = np.dstack([base * 0.94, base * 0.97, base * 1.02])
    albedo = mix_rgb(albedo, np.dstack([np.full((size, size), 0.30, np.float32),
                                       np.full((size, size), 0.16, np.float32),
                                       np.full((size, size), 0.09, np.float32)]), rust * 0.8)
    rough = np.clip(0.38 + 0.12 * rust + 0.10 * seam + 0.06 * brushed, 0.12, 1.0)
    return {"height": height, "albedo": albedo, "rough": rough,
            "normal_strength": 1.6, "ao_strength": 1.2, "ao_radius": 0.02,
            "uv": 3.0, "metallic": 0.75, "tint": (0.78, 0.82, 0.90)}


def gen_planks(size, rng):
    x, y = _grid(size)
    rows = 5
    row = np.floor(y * rows).astype(np.int32)
    fv = y * rows - row
    dv = np.minimum(fv, 1.0 - fv) / rows
    gap = 1.0 - smoothstep(0.0, 0.0025, dv)

    plank_var = hash01(row.astype(np.float32) * 3.0, np.zeros_like(row, np.float32))
    grain = fbm(size, 0.09, rng, sx=0.12, sy=1.0, octaves=5)
    knot_n = fbm(size, 0.02, rng, octaves=3)
    knot = smoothstep(1.35, 1.75, knot_n)

    height = 0.60 + 0.05 * grain - 0.35 * gap - 0.05 * knot
    base = 0.30 + 0.09 * plank_var
    albedo = np.dstack([base * 1.15, base * 0.82, base * 0.58])
    albedo *= (0.86 + 0.20 * grain)[..., None]
    albedo *= (0.92 + 0.12 * plank_var)[..., None]
    albedo *= (1.0 - 0.45 * gap)[..., None]
    albedo = mix_rgb(albedo, np.dstack([np.full((size, size), 0.14, np.float32),
                                       np.full((size, size), 0.09, np.float32),
                                       np.full((size, size), 0.055, np.float32)]), knot * 0.6)
    rough = np.clip(0.86 + 0.07 * grain + 0.08 * gap, 0.4, 1.0)
    return {"height": height, "albedo": albedo, "rough": rough,
            "normal_strength": 1.7, "ao_strength": 1.3, "ao_radius": 0.02,
            "uv": 6.0, "metallic": 0.0, "tint": (0.70, 0.62, 0.52)}


def gen_roof(size, rng):
    x, y = _grid(size)
    cols, rows = 12, 10
    row = np.floor(y * rows).astype(np.int32)
    offset = (row % 2) * 0.5
    u = (x + offset) * cols
    col = np.floor(u).astype(np.int32)
    fu = u - col
    fv = y * rows - row

    # черепица: выпуклая по X, нахлёст по Y (верхняя кромка темнее и ниже)
    curve = np.sin(np.pi * np.clip(fu, 0.0, 1.0)) ** 0.7
    overlap = smoothstep(0.0, 0.22, fv)
    side_gap = 1.0 - smoothstep(0.0, 0.05, np.minimum(fu, 1.0 - fu))
    var = hash01(col.astype(np.float32), row.astype(np.float32))
    grain = fbm(size, 0.25, rng, octaves=3)

    height = 0.35 + 0.30 * curve * (0.55 + 0.45 * overlap) - 0.18 * side_gap + 0.03 * grain
    base = 0.26 + 0.10 * var
    albedo = np.dstack([base * 1.05, base * 0.72, base * 0.58])
    albedo *= (0.75 + 0.35 * curve * (0.55 + 0.45 * overlap))[..., None]
    albedo *= (1.0 - 0.35 * side_gap)[..., None]
    albedo *= (0.94 + 0.10 * grain)[..., None]
    rough = np.clip(0.82 + 0.10 * grain + 0.06 * side_gap, 0.4, 1.0)
    return {"height": height, "albedo": albedo, "rough": rough,
            "normal_strength": 2.0, "ao_strength": 1.2, "ao_radius": 0.03,
            "uv": 4.0, "metallic": 0.0, "tint": (0.66, 0.60, 0.58)}


GENERATORS = {
    "asphalt": gen_asphalt,
    "brick": gen_brick,
    "concrete": gen_concrete,
    "plaster": gen_plaster,
    "metal": gen_metal,
    "dock_planks": gen_planks,
    "roof": gen_roof,
}


# ------------------------------------------------------------------ материалы

# Материалы по наборам: (файл, набор, uv, tint, metallic, specular, roughness, normal_scale, ao_light)
PBR_MATERIALS = [
    ("asphalt_pbr.tres", "asphalt", 22.0, (0.95, 0.98, 1.06), 0.22, 0.5, 0.75, 0.9, 0.35),
    ("brick_red_pbr.tres", "brick", 6.0, (0.92, 0.76, 0.72), 0.0, 0.35, 0.9, 1.0, 0.4),
    ("brick_grey_pbr.tres", "brick", 7.0, (0.66, 0.72, 0.84), 0.0, 0.35, 0.9, 1.0, 0.4),
    ("concrete_pbr.tres", "concrete", 5.0, (0.66, 0.69, 0.76), 0.0, 0.3, 0.95, 0.8, 0.4),
    ("plaster_pbr.tres", "plaster", 5.0, (0.72, 0.70, 0.68), 0.0, 0.3, 0.93, 0.7, 0.4),
    ("metal_pbr.tres", "metal", 3.0, (0.62, 0.66, 0.74), 0.75, 0.55, 0.5, 0.8, 0.3),
    ("dock_planks_pbr.tres", "dock_planks", 6.0, (0.66, 0.58, 0.48), 0.0, 0.35, 0.88, 1.0, 0.4),
    ("roof_pbr.tres", "roof", 4.0, (0.58, 0.56, 0.56), 0.0, 0.3, 0.92, 0.9, 0.35),
]

# Простые материалы для пропсов (без текстур — чистая база под ночь).
PLAIN_MATERIALS = [
    ("prop_wood_olive.tres", (0.16, 0.17, 0.10), 0.0, 0.4, 0.82),
    ("prop_plastic.tres", (0.10, 0.20, 0.34), 0.0, 0.55, 0.42),
    ("prop_sign_white.tres", (0.72, 0.71, 0.66), 0.0, 0.5, 0.5),
    ("prop_bag_dark.tres", (0.045, 0.05, 0.055), 0.0, 0.3, 0.62),
    ("prop_rust.tres", (0.20, 0.11, 0.07), 0.6, 0.5, 0.78),
]


def write_pbr_material(filename, key, uv, tint, metallic, specular, roughness,
                       normal_scale, ao_light):
    tex = "assets/textures/%s/%s" % (key, key)
    ext = [("1_albedo", tex + "_diff_2k.png"), ("2_normal", tex + "_normal_2k.png"),
           ("3_rough", tex + "_rough_2k.png"), ("4_ao", tex + "_ao_2k.png")]
    lines = ['[gd_resource type="StandardMaterial3D" load_steps=%d format=3]' % (len(ext) + 1), ""]
    lines.append("; Процедурная PBR-текстура (tools/gen_pbr_textures.py), 2k, без внешних ассетов.")
    lines.append("")
    for ext_id, rel in ext:
        lines.append('[ext_resource type="Texture2D" path="res://%s" id="%s"]' % (rel, ext_id))
    lines.append("")
    lines.append("[resource]")
    lines.append('resource_name = "%s"' % filename.replace(".tres", ""))
    lines.append('albedo_texture = ExtResource("1_albedo")')
    lines.append("albedo_color = Color(%.3f, %.3f, %.3f, 1)" % tint)
    lines.append("metallic = %.2f" % metallic)
    lines.append("metallic_specular = %.2f" % specular)
    lines.append("roughness = %.2f" % roughness)
    lines.append('roughness_texture = ExtResource("3_rough")')
    lines.append("roughness_texture_channel = 0")
    lines.append("normal_enabled = true")
    lines.append('normal_texture = ExtResource("2_normal")')
    lines.append("normal_scale = %.2f" % normal_scale)
    lines.append("ao_enabled = true")
    lines.append('ao_texture = ExtResource("4_ao")')
    lines.append("ao_texture_channel = 0")
    lines.append("ao_light_affect = %.2f" % ao_light)
    lines.append("uv1_scale = Vector3(%.1f, %.1f, %.1f)" % (uv, uv, uv))
    lines.append("")
    path = os.path.join(MAT_DIR, filename)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    return path


def write_plain_material(filename, color, metallic, specular, roughness):
    lines = ['[gd_resource type="StandardMaterial3D" format=3]', "", "[resource]",
             'resource_name = "%s"' % filename.replace(".tres", ""),
             "albedo_color = Color(%.3f, %.3f, %.3f, 1)" % color,
             "metallic = %.2f" % metallic,
             "metallic_specular = %.2f" % specular,
             "roughness = %.2f" % roughness, ""]
    path = os.path.join(MAT_DIR, filename)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    return path


# ------------------------------------------------------------------- запись

def save_rgb(path, arr):
    data = np.clip(arr * 255.0 + 0.5, 0, 255).astype(np.uint8)
    Image.fromarray(data, "RGB").save(path, optimize=False)


def save_gray(path, arr):
    data = np.clip(arr * 255.0 + 0.5, 0, 255).astype(np.uint8)
    Image.fromarray(data, "L").save(path, optimize=False)


def tile_seam_error(img):
    """Оценка шва тайлинга: средняя |разница| краёв в долях 0..1."""
    arr = np.asarray(img, dtype=np.float32) / 255.0
    if arr.ndim == 3:
        arr = arr.mean(axis=2)
    return float(np.abs(arr[:, 0] - arr[:, -1]).mean() + np.abs(arr[0, :] - arr[-1, :]).mean()) / 2.0


def tile_seam_ratio(img):
    """Честная метрика шва: «край / соседние пиксели внутри» (1.0 = шва нет).

    Для узорных карт (кладка, доски, черепица) отношение >1 на линии стыка — норма:
    шов совпадает с расшивкой/гребнем, а не режет шум.
    """
    arr = np.asarray(img, dtype=np.float32) / 255.0
    if arr.ndim == 3:
        arr = arr.mean(axis=2)
    edge_x = float(np.abs(arr[:, 0] - arr[:, -1]).mean())
    inner_x = float(np.abs(arr[:, 1:] - arr[:, :-1]).mean())
    edge_y = float(np.abs(arr[0, :] - arr[-1, :]).mean())
    inner_y = float(np.abs(arr[1:, :] - arr[:-1, :]).mean())
    return (edge_x / max(inner_x, 1e-6), edge_y / max(inner_y, 1e-6))


def run(size=DEFAULT_SIZE, seed=DEFAULT_SEED, only=None):
    os.makedirs(TEX_DIR, exist_ok=True)
    os.makedirs(MAT_DIR, exist_ok=True)
    os.makedirs(ART_DIR, exist_ok=True)
    keys = list(GENERATORS) if not only else [k for k in only if k in GENERATORS]
    if not keys:
        raise SystemExit("неизвестные наборы: %s (доступны: %s)" % (only, ", ".join(GENERATORS)))

    manifest = {"generator": "tools/gen_pbr_textures.py", "size": size, "seed": seed,
                "license": "procedural (оригинальная генерация, без внешних ассетов)",
                "sets": {}, "materials": []}

    for key in keys:
        rng = np.random.default_rng(seed + sum(ord(ch) for ch in key))
        data = GENERATORS[key](size, rng)
        out_dir = os.path.join(TEX_DIR, key)
        os.makedirs(out_dir, exist_ok=True)
        normal = normal_from_height(size, data["height"], data["normal_strength"])
        ao = ao_from_height(size, data["height"], data["ao_strength"], data["ao_radius"])

        paths = {
            "diff": os.path.join(out_dir, "%s_diff_2k.png" % key),
            "normal": os.path.join(out_dir, "%s_normal_2k.png" % key),
            "rough": os.path.join(out_dir, "%s_rough_2k.png" % key),
            "ao": os.path.join(out_dir, "%s_ao_2k.png" % key),
        }
        save_rgb(paths["diff"], np.clip(data["albedo"], 0, 1))
        save_rgb(paths["normal"], normal)
        save_gray(paths["rough"], np.clip(data["rough"], 0, 1))
        save_gray(paths["ao"], ao)

        seams = {}
        ratios = {}
        for logical, path in paths.items():
            with Image.open(path) as img:
                seams[logical] = round(tile_seam_error(img), 4)
                ratios[logical] = [round(v, 3) for v in tile_seam_ratio(img)]
        manifest["sets"][key] = {
            "size": size,
            "uv": data["uv"],
            "metallic": data["metallic"],
            "files": {logical: os.path.relpath(path, ROOT).replace("\\", "/")
                      for logical, path in paths.items()},
            "seam_error": seams,
            "seam_ratio_xy": ratios,
        }
        max_ratio = max(max(v) for v in ratios.values())
        print("[tex] %-12s %dx%d  diff/normal/rough/ao  шов(max diff)=%.4f  ratio(max)=%.2f"
              % (key, size, size, max(seams.values()), max_ratio), flush=True)

    for item in PBR_MATERIALS:
        filename, key = item[0], item[1]
        if key not in keys:
            continue
        path = write_pbr_material(*item)
        manifest["materials"].append(os.path.relpath(path, ROOT).replace("\\", "/"))
        print("[mat] %s" % filename, flush=True)

    for item in PLAIN_MATERIALS:
        path = write_plain_material(*item)
        manifest["materials"].append(os.path.relpath(path, ROOT).replace("\\", "/"))
        print("[mat] %s" % item[0], flush=True)

    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)
    total = 0
    for key in keys:
        for path in manifest["sets"][key]["files"].values():
            total += os.path.getsize(os.path.join(ROOT, path))
    print("[tex] готово: %d наборов, %.1f MB, manifest: %s"
          % (len(keys), total / 1048576.0, os.path.relpath(MANIFEST, ROOT)), flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description="Процедурные PBR-текстуры 2k")
    parser.add_argument("--size", type=int, default=DEFAULT_SIZE)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--only", type=str, default=None,
                        help="через запятую: %s" % ", ".join(GENERATORS))
    args = parser.parse_args()
    only = [s.strip() for s in args.only.split(",")] if args.only else None
    try:
        return run(size=args.size, seed=args.seed, only=only)
    except Exception as exc:  # noqa: BLE001 — печатаем причину и выходим ненулевым кодом
        print("[tex] FAILED: %s: %s" % (type(exc).__name__, exc), flush=True)
        return 2


if __name__ == "__main__":
    sys.exit(main())
