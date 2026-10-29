# Атмосфера «Ночной смены» (T4): параметры, интеграция, проверка

Все значения ниже сняты с финальных файлов проекта. Скриншоты — реальные кадры Forward+
с RTX 3080, снятые отдельным одноразовым проектом-«фотографом» (порт 9090 не занимается,
живой инстанс игры не трогался; temp-проект удалён).

## Что сделано

| Файл | Назначение |
|---|---|
| `assets/environment/night_shift_env.tres` | готовый Environment (небо-градиент, туман, glow, ACES, SSR) |
| `assets/materials/*.tres` (15 шт.) | тюнинг под ночь: влажный асфальт, emissive-неон, окна, вода, металл |
| `assets/shaders/wet_asphalt.gdshader` + `assets/materials/asphalt_wet.tres` | опция: лужи + рябь от капель (процедурно, без текстур) |
| `assets/shaders/rain_overlay.gdshader` + `assets/materials/rain_overlay.tres` | опция: изморозь на экране (CanvasLayer поверх 3D) |

`scenes/world/block.tscn` не правился — Environment отдаётся ресурсом.

## Интеграция (одна строка)

```gdscript
# в scripts/world/world.gd (_ready) или вручную в редакторе
$WorldEnvironment.environment = load("res://assets/environment/night_shift_env.tres")
```

Опции, включать по желанию:

```gdscript
# мокрый асфальт с рябью вместо StandardMaterial3D
$Ground.material_override = load("res://assets/materials/asphalt_wet.tres")

# изморозь на экране
var layer := CanvasLayer.new(); layer.layer = 10
var rect := ColorRect.new(); rect.set_anchors_preset(Control.PRESET_FULL_RECT)
rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
rect.material = load("res://assets/materials/rain_overlay.tres")
layer.add_child(rect); add_child(layer)
```

## Environment: значения

| Параметр | Значение |
|---|---|
| background_mode | 2 (Sky) |
| sky: ProceduralSkyMaterial | top `(0.006, 0.011, 0.032)`, horizon `(0.058, 0.082, 0.145)`, sky_curve 0.12, sky_energy 0.9, ground horizon `(0.042, 0.056, 0.092)` |
| Sky | process_mode 2 (incremental), radiance_size 3 (256) |
| ambient_light_source / color / energy | 2 (Color) / `(0.18, 0.22, 0.35)` / 0.9 |
| ambient_light_sky_contribution | 0.35 |
| reflected_light_source | 2 (Sky) — отражения неба на мокром асфальте и воде |
| tonemap_mode | **3 = ACES**, exposure 1.1, white 6.0 |
| glow | enabled, hdr_threshold 0.85, hdr_scale 2.0, intensity 0.95, strength 1.05, bloom 0.06, blend 1 (screen), normalized, levels 1..5 = 0 / 0.35 / 0.8 / 0.75 / 0.45 |
| fog | enabled, **density 0.02**, light_color `(0.15, 0.2, 0.33)`, light_energy 0.9, aerial_perspective 0.3, sky_affect 0.35, sun_scatter 0 |
| ssr | enabled, max_steps 48, fade_in 0.12, fade_out 2.0, depth_tolerance 0.35 |
| adjustment | enabled, brightness 1.0, contrast 1.06, saturation 1.1 |

## Материалы: ключевые значения

| Материал | albedo | metallic / specular | roughness | emission |
|---|---|---|---|---|
| asphalt | `(0.055, 0.058, 0.068)` | 0.3 / 0.6 | 0.72 × noise-ramp (0…1, uv1_scale 32) | — |
| brick | `(0.15, 0.072, 0.062)` | 0.02 | 0.9 | — |
| concrete | `(0.112, 0.118, 0.134)` | 0.02 | 0.92 | — |
| metal | `(0.105, 0.115, 0.135)` | 0.9 / 0.55 | 0.32 | — |
| shop_front | `(0.058, 0.066, 0.092)` | 0.55 | 0.24 | — |
| neon_magenta | `(0.25, 0.03, 0.13)` | 0.0 | 0.25 | `(1, 0.16, 0.62)` × **2.2** |
| neon_cyan | `(0.03, 0.24, 0.3)` | 0.0 | 0.25 | `(0.14, 0.86, 1)` × **1.9** |
| window_warm | `(0.09, 0.07, 0.055)` | 0.0 | 0.35 | `(1, 0.66, 0.33)` × 1.6 |
| door_glass | `(0.04, 0.09, 0.11)` | 0.6 | 0.06 | `(0.3, 0.85, 1)` × 1.0 |
| lamp_glass | `(0.95, 0.8, 0.55)` | 0.0 | 0.25 | `(1, 0.74, 0.42)` × 5.0 |
| water | `(0.012, 0.032, 0.058)` | 0.9 / 0.5 | 0.05 | `(0.03, 0.075, 0.13)` × 0.35 |
| markings | `(0.52, 0.5, 0.42)` | 0.1 | 0.55 | `(1, 0.86, 0.6)` × 0.12 |
| dock_planks | `(0.105, 0.078, 0.06)` | 0.08 | 0.85 | — |
| car_dark | `(0.035, 0.045, 0.075)` | 0.92 / 0.6 | 0.16 + clearcoat 1.0/0.1 | — |
| sign_dark | `(0.018, 0.019, 0.026)` | 0.45 | 0.42 | — |

Почему неон 2.2/1.9, а не 5–6: при ACES + glow hdr_threshold 0.85 энергия выше ~3
выжигает ядро в белое и цвет теряется. В этих значениях ядро остаётся маджентовым/циановым,
а ореол делает bloom.

## Проверка

1. `godot --headless --path . --quit-after 300` → exit 0, в логе 0 `SCRIPT ERROR`, 1 `ERROR`
   (известный шум: порт 9090 занят живым инстансом).
2. Рендер Forward+ отдельным одноразовым проектом (копия scenes/scripts/assets, без автолоада,
   порт не занимается): кадры в этой папке. Шейдеры компилируются на реальном Vulkan.
3. В `real_02_shop.png` видно, что неон читается цветом, витрина светится, асфальт мокрый,
   силуэты зданий различимы; `real_03_alley_plaza.png` — переулок/площадь; `real_01_overview.png` — общий вид.

### Скриншоты

- `real_01_overview.png … real_04_pier.png` — реальная сцена `scenes/main.tscn` + мой Environment
  и мои материалы (финальные значения).
- `01_shop_asphalt.png`, `02_street_asphalt.png` — тестовая мини-сцена: стандартный асфальт
  (рекомендуемый вариант, стоит в block.tscn).
- `03_street_wet_shader.png` — та же мини-сцена с `asphalt_wet.tres` (шейдер): темнее, зато с
  анимированной рябью; для эталонного кадра беру стандартный материал.
- `04_street_wet_rain.png` — изморозь `rain_overlay.tres` поверх: тонкие штрихи, HUD не перекрывают.

## Что осталось на стороне сцены (T1/интегратор)

1. Пирс (`real_04_pier.png`) почти не освещён: `LampPierEnd`/`LampPierTop` дают только точку света
   на столбе, настил остаётся чёрным. Поможет `light_energy` 2.0→3.0 и `omni_range` ≥ 12 у этих
   двух ламп (или одна дополнительная лампа над настилом) — это `block.tscn`, я его не правил.
2. Environment подключается одной строкой (см. выше); старый встроенный `EnvNight` можно оставить
   как fallback.
