# Реализм ассетов: PBR-текстуры и CC0-пропсы (t13 / t14)

> **Актуальный документ — `docs/art/README.md`.** Этот файл остаётся исходным планом
> CC0-пака Poly Haven. CDN-хосты Poly Haven/ambientCG в сети недоступны (замеры — в README),
> поэтому пак собран процедурно (`tools/gen_pbr_textures.py`), а пропсы — из примитивов
> (`scenes/props/props.tscn`). Путь CC0 сохранён и включается одной командой, когда сеть
> позволит: `tools/fetch_art_assets.py` + `tools/build_art_pack.py`.

Арт-директор: Сакура. Все внешние ассеты — **Poly Haven, лицензия CC0**
(<https://polyhaven.com/license>), ничего проприетарного, архивы целиком не качаются.
Только 2k-текстуры и glTF 1k-модели, чтобы проект не распухал.

Статус: **id-списки заменены на проверенные капитаном, резолвер валидирует карты.**
У роли `art-director` в этой сессии нет shell/сети (`design-research`), поэтому скачивание
и прогон Godot выполняет капитан; команды — в конце документа.

## 1. Конвейер (3 файла, идемпотентно)

| Шаг | Файл | Что делает |
| --- | --- | --- |
| 1 | `tools/fetch_art_assets.py` | Poly Haven API: 7 наборов текстур 2k (diff / nor_gl / rough / AO) и 10 моделей glTF 1k; качает в `assets/textures/<id>/` и `assets/models/props/<id>/`; пишет `docs/art/asset_manifest.json` |
| 2 | `tools/build_art_pack.py` | офлайн: `assets/materials/*_pbr.tres`, `scenes/world/props.tscn`, `assets/models/props/LICENSE.md`, `docs/art/asset_manifest.md` |
| 3 | `tools/art_pack.py` | одна команда = fetch + build (+ `--verify` → импорт и headless-прогон) |

Резолвер жёстко валидирует ассет до скачивания: у набора должны быть **Diffuse + nor_gl +
Rough** (AO желателен), у модели — `gltf/1k`. Если у id карт нет — берётся следующий
кандидат из списка, потом keyword-фолбэк. Именно на этом упал первый прогон
(`asphalt_02` без карт) — теперь такой ассет не выбирается вообще.
id сравниваются case-insensitive: в Poly Haven есть legacy-написания (`WetFloorSign_01`).

Повторный запуск докачивает недостающее и перегенерирует .tres/сцену. Скачанные файлы
не перезаписываются. 8k не запрашивается вообще.

## 2. Наборы текстур → материалы → где применены

`uv1_scale` — по размеру поверхности: асфальт 8–16, кирпич 4–8, остальное 3–6
(текстуры на CSG-боксах, один повтор на грань × множитель). Тона ночные: albedo-текстуры
сняты днём, поэтому материал домножает их холодным/тёмным `albedo_color` под ACES-ночь
(неон и окна не пересвечиваются).

| Набор | id Poly Haven (проверены, фактические — в `asset_manifest.json`) | Карты | Материал | uv1_scale | Где применён |
| --- | --- | --- | --- | --- | --- |
| асфальт | `asphalt_01` → `asphalt_03` → `asphalt_05` | diff, nor_gl, rough, ao | `assets/materials/asphalt_pbr.tres` | 14 | `Ground`, дорога |
| кирпич | `brick_4` → `brick_crosswalk` → `brick_floor_003` | diff, nor_gl, rough, ao | `brick_red_pbr.tres` (тёплый тон) | 6 | `Buildings/BuildingA`, стены магазина |
| кирпич (серый тон) | тот же `brick_4` | — | `brick_grey_pbr.tres` (холодный тон) | 7 | резерв для построек Эрена (t18) |
| бетон | `concrete_wall_008` → `concrete_wall_004` → `brushed_concrete` | diff, nor_gl, rough, ao | `concrete_pbr.tres` | 5 | `BuildingB`, `Perimeter/*`, `Alley/BackWall`, `Slope` |
| штукатурка | `beige_wall_001` → `blue_plaster_wall` → `clay_plaster` → `damaged_plaster` | diff, nor_gl, rough, ao | `plaster_pbr.tres` | 5 | резерв: задние стены, крыша магазина |
| металл | `metal_plate_02` → `metal_plate` → `corrugated_iron_02` → `blue_metal_plate` | diff, nor_gl, rough, ao | `metal_pbr.tres` | 3 | двери, ставни, ограждения (опционально, см. §5) |
| доски пирса | `brown_planks_03` → `brown_planks_04` → `wood_planks` → `plank_flooring_02` | diff, nor_gl, rough, ao | `dock_planks_pbr.tres` | 6 | `Waterfront/PierDeck`, `Alley/Crate` |
| крыша/рубероид | `ceramic_roof_01` → `clay_roof_tiles` → `clay_roof_tiles_02` | diff, nor_gl, rough, ao | `roof_pbr.tres` | 4 | резерв: крыши |

Итого 7 скачанных наборов и 8 материалов (два кирпичных варианта используют одну текстуру,
различаясь тоном и масштабом — отдельная закачка «серого кирпича» не нужна, такого ассета
с полным набором карт в Poly Haven нет).

Файлы текстур: `assets/textures/<id>/<id>_{diff,normal,rough,ao}_2k.jpg` (модели — 1k).
Переименование в `_diff/_normal/_rough/_ao` — не косметика: по этим суффиксам импортёр
Godot 4 сам ставит sRGB для albedo, linear + normal-map для `nor_gl`, linear для roughness/AO.
`nor_gl` → `normal_texture` (OpenGL-конвенция, зелёный канал как в Godot). Если у ассета
вместо отдельных карт есть `arm`, roughness берётся из зелёного канала
(`roughness_texture_channel = 1`) — это фиксируется в манифесте.

Старые материалы (`asphalt.tres`, `brick.tres`, `concrete.tres`, `metal.tres`,
`dock_planks.tres`) **не тронуты** — новые лежат рядом с суффиксом `_pbr`, сцена работает
на любом наборе.

## 3. Пропсы: 16 экземпляров, `scenes/world/props.tscn`

Модели — glTF 1k из Poly Haven (10 ролей из проверенных id: `metal_trash_can`,
`wooden_crate_01/02`, `old_military_crate`, `plastic_crate_01`, `barrel_01`,
`painted_wooden_bench`, `modular_industrial_pipes_01`, `wooden_ladder`,
`WetFloorSign_01`, `trashbag`). Расстановка вручную по координатам `block.tscn`;
у пропсов **нет коллизий** — проходы и NPC-слоты не блокируются.

| Узел | Роль | Позиция (x, y, z) | Поворот Y | Комментарий |
| --- | --- | --- | --- | --- |
| TrashCanShop | trash_can | 1.35, 0, -10.55 | 0° | у правого угла витрины, в 3.5 м от `NPC_Phone` |
| WetSignShop | wet_sign | 0.20, 0, -11.40 | 10° | у входа в магазин, в 2.1 м от `NPC_Phone` |
| BarrelPier | barrel | 2.15, -0.70, 37.80 | 20° | у правого ограждения пирса |
| BarrelAlleyA | barrel | 5.15, 0, -20.90 | 20° | переулок, у стены BuildingB |
| BarrelAlleyB | barrel | 5.20, 0, -19.80 | -12° | там же |
| CrateAlleyA | crate_wood | 2.45, 0, -16.40 | 8° | у стены магазина |
| CrateAlleyA_top | crate_wood | 2.50, 0.82, -16.35 | -6° | второй ящик сверху, scale 0.85 |
| CrateMilitaryAlley | crate_military | 5.25, 0, -15.10 | 15° | у стены BuildingB |
| CratePlasticAlley | crate_plastic | 4.95, 0, -13.20 | -25° | у устья переулка |
| TrashBagAlley | trashbag | 2.50, 0, -23.20 | 0° | у задней стены переулка |
| PipesWallA | pipes | 5.80, 1.40, -6.40 | -90° | трубы по стене BuildingB |
| PipesWallB | pipes | 5.80, 1.40, -2.00 | -90° | там же, южнее |
| LadderAlley | ladder | 2.30, 0, -21.00 | 90° | лестница у стены магазина |
| BenchSeafront | bench | -6.60, 0, 20.30 | 180° | спиной к морскому ограждению |
| CratePier | crate_wood | 2.05, -0.70, 36.20 | 25° | у правого ограждения пирса |
| TrashCanPier | trash_can | -2.15, -0.70, 28.00 | 0° | у левого ограждения пирса |

Свободные коридоры соблюдены: спавн `(0, 0.1, 10)` → магазин `(-4, 0, -10.9)`,
→ переулок `(4, 0, -11.6)`, → пирс `(0, -0.7, 34.5)`. Ни один проп не ближе 1.2 м
к маркерам POI и NPC-слотам, кроме `WetSignShop` (2.1 м до `NPC_Phone`) и
`TrashCanShop` (3.5 м) — с запасом.

Позиции — арт-задание, не привязка к геометрии моделей: origin у glTF разный, поэтому
после первого рендера допустима подстройка `y` на ±0.1–0.3 м (трубы и лестница особенно:
они могут «висеть» или «тонуть» — их ставить по стене уже на месте).

## 4. Лицензии

`assets/models/props/LICENSE.md` (генерируется) — таблицы «id → страница → CC0» для всех
моделей и текстур. Атрибуция CC0 не требуется, но фиксируется для трассировки.
Скрипты ничего не берут с других сайтов и не качают zip-архивы: только отдельные файлы
по прямым ссылкам `dl.polyhaven.org`, которые отдаёт официальное API.

## 5. Что заменено, что осталось

**Заменяется безопасно** (только path в `ext_resource`, узлы/имена/коллизии не трогаются):

| Было | Стало |
| --- | --- |
| `assets/materials/asphalt.tres` | `asphalt_pbr.tres` |
| `assets/materials/brick.tres` | `brick_red_pbr.tres` |
| `assets/materials/concrete.tres` | `concrete_pbr.tres` |
| `assets/materials/dock_planks.tres` | `dock_planks_pbr.tres` |

Металл (`metal.tres` → `metal_pbr.tres`) — **опционально**: настоящий металл с
metallic 0.75 ночью уходит в тёмный силуэт без отражений неба. Включать только после
проверки кадра, флагом `--apply-block-metal`.

**Не применено и почему:**

1. **`block.tscn` не правился (t13).** Файл параллельно ведёт level-designer (Эрен, t18):
   правка в те же минуты = конфликт. Готовая команда замены материалов —
   `python tools\build_art_pack.py --apply-block` — запускается после того, как Эрен
   закончит сцену. Бэкап `tools/block_pre_pbr.tscn.bak` пишется автоматически.
2. **HDRI не подключена.** `assets/environment/night_shift_env.tres` (t4) построен на
   ProceduralSky с выверенной ночной палитрой (top 0.006/0.011/0.032, ambient energy 0.9,
   ACES + glow hdr_threshold 0.85). HDRI даёт другой баланс: небо становится «фотографическим»,
   амбиент светлее, и неон 2.2/1.9 теряет контраст — палитра квартала ломается.
   Вывод: оставить ProceduralSky; HDRI — только если арт-решение изменится на «реальный
   ночной город», тогда отдельной задачей с пересборкой Environment.
3. **UV-развёртка моделей-пропсов** — родная из glTF; материалы к пропсам не навязываются,
   иначе теряются их собственные текстуры.

## 6. Интеграция (Рэм, t20) — точная вставка `props.tscn` в `scenes/main.tscn`

1. Сначала выполнить пак (см. §7), чтобы `scenes/world/props.tscn` существовал и Godot
   проимпортировал модели.
2. В `scenes/main.tscn` добавить **одну** внешнюю сцену и **одну** ноду:

```ini
[ext_resource type="PackedScene" path="res://scenes/world/props.tscn" id="20_props"]
```

```ini
[node name="Props" parent="." instance=ExtResource("20_props")]
```

3. Место в дереве: **дочерний узел корня `Main`, сразу после `World`** (до `Player` и `UI`).
   `Props` — самодостаточный `Node3D` с мировыми координатами; родитель не должен иметь
   смещения/поворота, иначе пропсы «уедут». `load_steps` у `main.tscn` увеличить на 1.
4. Ничего переименовывать не нужно: `world.gd` про `Props` не знает и не должен.
5. Пропсы статичные (коллизий нет) — игрок и NPC проходят сквозь, если вплотную; это
   осознанно, чтобы не ловить застревания в переулке шириной 4 м.

Скринов через мост не делаю: живой инстанс занят капитаном (t20). Проверка — headless
по §7, плюс один кадр от капитана, если он свободен.

## 7. Команды (выполняет капитан, у роли нет shell)

```powershell
# 1. План без скачивания (быстро, проверить, что все id валидны) — необязательно
python tools\fetch_art_assets.py --dry-run

# 2. Скачивание CC0-ассетов (7 наборов текстур 2k + 10 моделей glTF 1k)
python tools\fetch_art_assets.py

# 3. Офлайн-сборка: материалы, props.tscn, LICENSE, сводка
python tools\build_art_pack.py

# 4. Импорт новых ресурсов и headless-проверка
& .\tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . --import
& .\tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . --quit-after 300 --log-file tools\t_art_hl.log
Select-String -Path tools\t_art_hl.log -Pattern "SCRIPT ERROR|ERROR: Parse"
```

Либо одной командой: `python tools\art_pack.py --verify` (шаги 2–4 + разбор лога).

Ожидаемо: exit 0, `SCRIPT ERROR` — 0, в логе допустим только известный шум
(cert store, `user://`-каталоги). Пакеты текстур и модели попадают в рендер только после
интеграции `Props` в `main.tscn` (п. 6) — сама проверка headless подтверждает, что
сгенерированные ресурсы валидны и проект грузится.

## 8. Что осталось после интеграции

1. Подстройка `y`/поворотов пропсов по первому кадру (origin моделей разный).
2. Решение по металлу: включать ли `metal_pbr` (см. §5) — нужно посмотреть ночной кадр.
3. Крыши и штукатурка ждут новых построек Эрена (t18): материалы уже лежат в
   `assets/materials/`, применять по его геометрии.
4. Замена `asphalt.tres` на `asphalt_pbr` может сделать асфальт светлее эталона t4:
   при необходимости опустить albedo-множитель с 0.55 до 0.42 (константа в
   `tools/build_art_pack.py`, блок `MATERIALS`).
