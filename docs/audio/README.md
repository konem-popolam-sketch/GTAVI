# Звук «Ночной смены» (t12, дождь переписан в t28)

Вся аудиосистема игры: шины, автолоад `AudioManager`, процедурно синтезированные
ассеты, шаги игрока, окружение с зонами, озвучка диалогов и сохранение громкости.
Внешних сэмплов и сети нет — WAV-файлы считает `tools/gen_audio.py` (Python + numpy).

## 1. Шины

`default_bus_layout.tres` в корне проекта (его подхватывает настройка
`audio/buses/default_bus_layout` по умолчанию). `AudioManager` при старте ещё раз
применяет те же значения из `DEFAULT_BUS_DB`:

| Шина | ДБ по умолчанию | Линейно (≈) | Что идёт |
|---|---|---|---|
| `Master` | 0 | 1.000 | всё, сумма |
| `Music` | −12 | 0.251 | музыкальная петля (ночь, минор) |
| `SFX` | −8 | 0.398 | шаги, клики UI, скрип двери, гудок, «взял предмет» |
| `Voice` | −4 | 0.631 | озвучка реплик (задача t13) |
| `Ambience` | **−18** | 0.126 | дождь и зоны окружения (t28: было −14) |

Линейная громкость каждой шины (`AudioManager.get_bus_volume`) хранится в
`user://audio.cfg` (ConfigFile, секция `[bus]`, ключи `master/music/sfx/voice/ambience`)
и читается в `_ready()` автолоада. Шина `Music` дополнительно приглушается на
−6 дБ, пока идёт диалог (`set_music_duck`), это не сохраняется на диск.

`meta/version = 2` (t28): у старых конфигов (v1, Ambience = −14 дБ) при загрузке
сбрасывается только `ambience` на новое значение −18 дБ (0.126 linear); музыка,
SFX и голос пользователя не трогаются. Новый конфиг создаётся лениво — при первом
`set_bus_volume` или миграции.

## 2. Каталоги и файлы

```
assets/audio/sfx/        step_asphalt_01..04, step_wood_01..02,
                         horn_distant, door_creak, ui_click, pickup
assets/audio/ambience/   rain_light_loop, rain_heavy_loop, city_hum_loop,
                         neon_hum_loop, water_wind_loop
assets/audio/music/      mus_night_shift_loop
assets/audio/voice/      <dialogue_id>_<node_id>.wav  (рендерит t13, здесь только чтение)
```

Формат всех файлов: WAV PCM, 44.1 кГц, 16 бит. Дождь (t28) — **моно**,
пик **−6 dBFS**: это фон, он не должен перекрывать шаги и голос. Остальные петли
окружения и музыка — стерео, пик −1 dBFS; короткие SFX (шаги, клик, скрип) — моно,
пик −1 dBFS. Петли склеены кроссфейдом: у дождя cos/sin 0.5 с, у прочих петель
окружения cos/sin 1.5–2.5 с, у музыки — **линейное окно 3 с** (её хвост и начало —
одна и та же 16-тактовая аранжировка, cos/sin дал бы всплеск до +3 дБ); после точки
петли дорисовано 2 такта аранжировки, чтобы хвост не был тишиной. Стык оценивается
по RMS первой и последней секунды (`tools/t12_audio_report.txt`, столбец
«стык петли, dB»): у музыки лимит 2 дБ, у дождя 1 дБ, у остальных 6 дБ.

| Файл | Длит. | Тип | Где играет |
|---|---|---|---|
| `rain_light_loop` | 24 с | петля, моно, пик −6 | тихий фоновый дождь (подложка окружения) |
| `rain_heavy_loop` | 28 с | петля, моно, пик −6 | плотнее и ниже; чередуется с лёгким ~раз в 34 с |
| `city_hum_loop` | ~30 с | петля | зона у забора/парковки (далёкий город) |
| `neon_hum_loop` | ~22 с | петля | зона у магазина «Луна» (неон, 100 Гц гул, треск) |
| `water_wind_loop` | ~26 с | петля | пирс: ветер + вода |
| `mus_night_shift_loop` | ~42.7 с | петля, стерео, стык ≤2 дБ | музыка на старте (A minor, 90 BPM, i–VI–III–VII) |
| `step_asphalt_01..04` | ~0.24 с | one-shot | шаги по асфальту (4 варианта) |
| `step_wood_01..02` | ~0.30 с | one-shot | шаги по настилу пирса |
| `horn_distant` | ~3.2 с | one-shot | далёкий гудок (атмосфера, при желании — триггер) |
| `door_creak` | ~1.7 с | one-shot | скрип двери |
| `ui_click` | ~0.09 с | one-shot | клик интерфейса (шина SFX) |
| `pickup` | ~0.62 с | one-shot | «взял предмет» |

### 2.1 Дождь: рецепт t28

Пользователь просил сделать дождь мягче: «слишком громкий и раздражающий».
Переписаны обе петли (`synth_rain` в `tools/gen_audio.py`):

* шум только **200–2500 Гц**; выше 2 кГц — спад **−6 дБ/октаву** (однополюсный
  фильтр в `rain_texture`), никакого «шелеста» 5–15 кГц;
* низкочастотный гул города **40–120 Гц** (42/58/76/96/112 Гц, очень тихий);
* вместо капель-«тиканий» — редкие мягкие «плюхи»: синус 65–140 Гц, атака 30 мс,
  затухание 120–200 мс, **0.55/с** у light и **1.7/с** у heavy (лимит 4/с),
  амплитуда 13 % от шума (лимит 15 %);
* `rain_heavy` плотнее и ниже: полоса 165–1800 Гц плюс слой 140–1150 Гц, больше
  гула и «плюх»; громкость при этом не выше — обе петли в пике −6 dBFS, а RMS
  выравнивается в пределах ±1 дБ (генератор печатает `[rain] RMS light/heavy` и
  падает, если разница больше 1 дБ);
* кроссфейд хвоста в начало 0.5 с; стык (RMS первой и последней секунды) < 1 дБ —
  генератор проверяет это отдельным лимитом `seam_limit_db = 1.0` для дождя.

Итог по уровню: раньше дождь шёл с пиком −1 dBFS на шине −14, теперь пик −6 dBFS
на шине −18 — примерно на 9 дБ тише и существенно глуше по спектру. Значение
`0.55 linear` из задания не используется как громкость шины: −18 dBFS-шина
соответствует 0.126 linear, а 0.55 (−5.2 dB) сделало бы дождь на 9 дБ **громче**
прежнего; при желании это правится одной строкой в `DEFAULT_BUS_DB`.

## 3. API автолоада `AudioManager`

Обязательный контракт (`docs/PHASE2.md`):

```gdscript
AudioManager.play_sfx(name, position = null, volume_db = 0.0) -> Node
AudioManager.play_voice(dialogue_id, node_id) -> bool
AudioManager.set_bus_volume(bus_name, linear)
AudioManager.get_bus_volume(bus_name) -> float
AudioManager.is_voice_playing() -> bool
AudioManager.stop_voice()
```

`position`: `null` — плоский звук (UI/интерфейс), `Vector3` или `Node3D` — 3D-источник
с панорамой и затуханием. `name` — имя файла без `.wav` (`"ui_click"`, `"step_wood_01"`)
или полный `res://`-путь.

Дополнительно:

```gdscript
AudioManager.play_ambience(name, fade = 1.0, volume_db = 0.0) -> bool
AudioManager.stop_ambience(fade = 1.0)
AudioManager.play_music(name, fade = 1.0, volume_db = 0.0) -> bool
AudioManager.stop_music(fade = 1.0)
AudioManager.register_player(node)              # шаги по движению игрока
AudioManager.set_footstep_surface("wood")       # "asphalt" | "wood"
AudioManager.get_footstep_surface() -> String
AudioManager.set_music_duck(db)                 # приглушение музыки на диалог
AudioManager.is_ready() -> bool                 # громкости загружены и применены
AudioManager.get_stream(name, category, loop) -> AudioStream
AudioManager.list_audio_files() -> PackedStringArray
AudioManager.get_stream_length(path) -> float
AudioManager.get_bus_table() -> Array[Dictionary]
AudioManager.save_audio_config(); reload_audio_config(); reset_bus_volumes()
```

Сигналы:
* `bus_volume_changed(bus_name, linear)` — для UI-слайдеров (t17): слайдер
  вызывает `set_bus_volume`, значение сохраняется само;
* `audio_ready()` — автолоад прочитал `user://audio.cfg` и применил шины.

**Готовность (важно для UI/настроек, t47).** `AudioManager.is_ready()` возвращает
`false`, пока не загружены конфиг и заводские уровни; в этот момент вызывается
`audio_ready`. До готовности `get_bus_volume("Master")` отдаёт **заводское**
значение (1.0 = 0 dB), а не `0.0`, чтобы UI не принял «ещё не загрузилось» за
выбор пользователя и не сохранил `Master = 0.0` в свои настройки. Правильный
паттерн:

```gdscript
if not AudioManager.is_ready():
    await AudioManager.audio_ready
var master := AudioManager.get_bus_volume("Master")  # всегда осмысленное число
```

## 4. Шаги

`AudioManager` сам следит за `CharacterBody3D` из группы `player`: копит пройденный
путь, шагает раз в `clamp(скорость × 0.42, 0.95, 2.7)` м, берёт случайный вариант
поверхности, слегка рандомизирует громкость и `pitch_scale`. Молчит, когда игрок
стоит, в воздухе, на паузе (`get_tree().paused`) и во время диалога
(`DialogueManager.is_active()`).

Поверхность переключает `AmbienceController`: зона `pier_wood` у пирса ставит
`"wood"`, вне зон — `"asphalt"`. Внешнему коду ничего вызывать не нужно.
Отдельный `register_player()` — на случай, если игрок появляется позже сцены.

## 5. Окружение и зоны

`AmbienceController` (`scripts/audio/ambience_controller.gd`, узел на сцене):

* подложка дождя на `Ambience`, раз в ~34 с плавно (2.5 с) меняет петлю;
* зоны — отдельные `AudioStreamPlayer3D` с `attenuation_model = DISABLED`:
  затухание считается вручную по `inner_radius`/`outer_radius`, панорама — движком
  относительно камеры;
* координаты зон берутся из мировых маркеров `POI_Shop`, `POI_Pier`, `POI_Fence`
  через `World.get_poi()`, с запасными координатами из `block.tscn`;
* музыка стартует здесь же (`music_enabled`).

Зоны по умолчанию (можно переопределить массивом `zones` в инспекторе):

| id | звук | POI | inner/outer, м | volume_db | surface |
|---|---|---|---|---|---|
| `shop_neon` | `neon_hum_loop` | `POI_Shop` | 3.5 / 14 | −4 | — |
| `pier_water` | `water_wind_loop` | `POI_Pier` | 5 / 20 | −3 | — |
| `pier_wood` | — | `POI_Pier` | 6.5 / 8.5 | — | `wood` |
| `alley_hum` | `city_hum_loop` | `POI_Fence` | 3 / 12 | −9 | — |

## 6. Озвучка диалогов

`DialogueAudio` (`scripts/audio/dialogue_audio.gd`, узел на сцене) слушает
`DialogueManager`: `dialogue_started` → музыка тише на 6 дБ, `line_changed` →
`AudioManager.play_voice(dialogue_id, node_id)`, `dialogue_ended` → стоп озвучки и
возврат музыки. Файла нет — `play_voice` возвращает `false`, в лог уходит одна
строка `[dialogue_audio] озвучки нет (тихий режим): ...`, диалог идёт с субтитрами.
Управление игроком и пауза не затрагиваются.

Поиск файла: `voice/<dialogue_id>_<node_id>.wav` → `voice_manifest.json`
(ключи `dialogue_id → node_id → {file|voice_id}`, а также `voice_id → entry`) →
`voice/<node_id>.wav`.

## 7. Что добавить в `scenes/main.tscn` (делает интегратор, t20)

Автолоад уже прописан в `project.godot` (правил только `audio-director`):

```ini
[autoload]
AudioManager="*res://scripts/audio/audio_manager.gd"
```

Два узла в главной сцене — оба прямые дети корня `Main`, порядок не важен,
`Audio` удобно ставить после `Player`:

```text
Main (Node3D)
├── World
├── Player
├── Npcs
├── Audio          Node3D, script res://scripts/audio/ambience_controller.gd
│                  position = (0, 0, 0)
│                  rain_enabled = true, rain_volume_db = -2.0,
│                  rain_variants = ["rain_light_loop", "rain_heavy_loop"],
│                  rain_change_seconds = 34.0,
│                  music_enabled = true, music_name = "mus_night_shift_loop",
│                  music_volume_db = -3.0,
│                  zones = [] (пусто = координаты из World.get_poi),
│                  auto_register_player = true
└── DialogueAudio  Node, script res://scripts/audio/dialogue_audio.gd
                   enabled = true, duck_music_db = -6.0, log_missing_voice = true
```

Готовый фрагмент `.tscn` (ext_resource добавить в шапку сцены):

```ini
[ext_resource type="Script" path="res://scripts/audio/ambience_controller.gd" id="8_audio"]
[ext_resource type="Script" path="res://scripts/audio/dialogue_audio.gd" id="9_dialogue_audio"]

[node name="Audio" type="Node3D" parent="."]
script = ExtResource("8_audio")

[node name="DialogueAudio" type="Node" parent="."]
script = ExtResource("9_dialogue_audio")
```

Больше ничего в дерево добавлять не нужно: шаги, дождь, зоны, музыка и озвучка
включаются сами. UI-слайдеры (t17) могут вызывать `AudioManager.set_bus_volume` и
показывать `get_bus_volume` — API уже готов.

## 8. Перегенерация ассетов и проверки

```powershell
python tools/gen_audio.py                # синтез 16 файлов + tools/t12_audio_report.txt
python tools/gen_audio.py --verify       # только проверка готовых WAV
python tools/gen_audio.py --report-only  # пересобрать отчёт без синтеза
```

Генератор печатает таблицу и падает с кодом 1, если файл короче 0.05 с, пик выше
заданного для ассета потолка (дождь −6 dBFS, остальное −1 dBFS) или стык петли
хуже лимита (дождь 1 дБ, музыка 2 дБ, прочие петли 6 дБ). Отдельной строкой идёт
сводка `[rain] rain_light/rain_heavy: peak … RMS … стык … плюхи …/с` и разница RMS
пары (должна быть ≤ 1 дБ). Проверка касается только 16 синтезированных файлов
(`ambience/`, `sfx/`, `music/`). Озвучка в `assets/audio/voice/` рендерится
отдельным пайплайном (t13, piper, 22050 Гц) и проверяется только на читаемость —
её частота и пик в отчёт не входят.

Headless-проверка аудиосистемы (отдельная сцена — автолоады поднимаются):

```powershell
tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . `
    tests/audio_smoke.tscn --log-file tools\t12_smoke.log
```

Ищет в логе `T12 AUDIO SMOKE OK`; проверяет автолоад, 5 шин, ≥12 файлов,
длины петель, вызовы `play_sfx/play_ambience/play_music`, тихий `play_voice` для
отсутствующего файла, сохранение/чтение громкости и переключение поверхности шагов.

**Важно для CI/QA (как в `docs/pipeline.md`):** смоук и любой прогон, который
пишет `user://` (`audio.cfg`), требует изолированного APPDATA, иначе `user://`
доступен только на чтение и смоук честно падает на «не читается user://audio.cfg».
Перед запуском в PowerShell:

```powershell
$env:APPDATA="$PWD\.godot_profile"
```

(у Мисаки — свой APPDATA на порту `19095`). В логах при этом возможны 4×
`WARNING: [audio] не удалось сохранить user://audio.cfg (код 7)` — это песочница,
на звук и утечки не влияет.

Обычный headless-прогон сцены (в логе видно, что шина применилась):

```powershell
tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . `
    --quit-after 600 --log-file tools\t28_hl.log
Select-String -Path tools\t28_hl.log -Pattern "\[audio\]|SCRIPT ERROR|leaked"
```

Ожидаемые строки: `[audio] конфиг v1 → v2: Ambience -18.0 dB` (только при первом
старте после t28) и `[audio] AudioManager готов: шин 5 [... Ambience -18.0 dB ...]`.
Строк `leaked` быть не должно: перед выходом `AudioManager.shutdown()` гасит петли.
Регрессию утечки проверять именно 600-кадровым прогоном: ветка гашения по
`--quit-after` в обычной игре без аргумента неактивна.

## 9. Как добавить новый звук

1. Положить WAV (или сгенерировать) в `assets/audio/<категория>/<name>.wav`
   с именем в стиле `sfx_ui_button_click_01` / `amb_env_rain_loop` — имя файла и
   есть ключ, по которому его ищет `AudioManager`.
2. Для синтеза — добавить словарь в кортеж `ASSETS` в `tools/gen_audio.py`
   (`path`, `loop`, `peak_db`, `seam_limit_db`, лямбда-генератор) и запустить
   генератор: нормализация, кроссфейд и проверка пика применятся автоматически.
3. Для петли — убедиться, что генератор возвращает «сырой» сигнал длиннее
   нужного на длину кроссфейда: `crossfade_loop(data, fade)` сам склеит стык.
4. Вызвать из игры: `AudioManager.play_sfx("my_sound", position, -3.0)` или
   `AudioManager.play_ambience("my_loop", 2.0)`.
5. Если нужна новая зона — добавить словарь в `AmbienceController.zones`
   (инспектор) или в `_build_default_zones()`.

## 10. Технические заметки

* WAV читается и **без импорта**: если `ResourceLoader` не знает файл,
  `AudioManager` сам разбирает RIFF/PCM 16 бит. Поэтому звук работает и в чистом
  клоне проекта, где `--import` ещё не запускали.
* Импортированные `AudioStreamWAV` для петель копируются (`duplicate()`) перед
  включением `loop_mode`, чтобы не менять общий ресурс.
* Все проигрыватели живут у автолоада (`process_mode = ALWAYS`), поэтому
  кроссфейды дождя и музыки не замирают на паузе.
* На выходе (закрытие окна / `quit`) `AudioManager.shutdown()` и
  `AmbienceController.shutdown()` глушат playback'и, обнуляют `stream` и чистят
  кэш потоков. Без этого движок печатает `ObjectDB instances were leaked at exit`
  (AudioStreamWAV + AudioStreamPlaybackWAV петель дождя, музыки и зон).
* Для CI-прогонов `--quit-after N` автолоад читает N из `OS.get_cmdline_args()`
  и гасит звук за 3 кадра до выхода: движок завершается без сигнала сцене, и
  иначе те же playback'и не успевают вычиститься из AudioServer. В обычной игре
  (без аргумента) этот путь не активен — работают `WM_CLOSE_REQUEST` и
  `NOTIFICATION_EXIT_TREE`.
* Громкость 0 линейная → −80 дБ, а не `-inf`: так шину можно вернуть без щелчка.
* `user://audio.cfg` сохраняется при каждом `set_bus_volume`; стартовые значения
  берутся из `DEFAULT_BUS_DB` (`Master 0, Music −12, SFX −8, Voice −4, Ambience −18`).
  При первом старте после t28 старый конфиг (v1) автоматически мигрирует: только
  `ambience` меняется на 0.126 linear (−18 дБ), остальные ползунки сохраняются.

## 11. Машина: дверца и петля двигателя (t53 + t54)

**Дверца.** `scripts/vehicles/car.gd` при входе и выходе зовёт
`AudioManager.play_sfx("car_door", global_position)` — 3D-источник стоит в точке
машины, поэтому звук не «плавает» в центре мира. Раньше файла не было — живой лог
писал 12 WARNING «play_sfx: файл не найден — car_door», дверца была немой.

**Петля двигателя.** `car.gd` сам создаёт `AudioStreamPlayer3D` (`Car/EngineAudio`,
кодом в `_ready`, сцену не правили) и берёт поток рецептом из этого раздела:
`AudioManager.get_stream("car_engine_loop", "sfx", true)` — `get_stream` уже
копирует ресурс и включает `loop_mode`, `duplicate()` не нужен.

| файл | длит. | параметры | как играет |
| --- | --- | --- | --- |
| `assets/audio/sfx/car_door.wav` | 0.22 с | защёлка 180–900 Гц (атака 3 мс, спад 100 мс) + металлический призвук 1.2–2.6 кГц + стук 78 Гц в конце; пик −1 dBFS, RMS ≈ −20 dBFS | `play_sfx("car_door", global_position)` на enter/exit |
| `assets/audio/sfx/car_engine_loop.wav` | 2.20 с | гул 55–140 Гц + шум; петля (кроссфейд 0.35 с, стык +0.62 дБ), пик −6 dBFS | `AudioStreamPlayer3D` ребёнком машины, шина `SFX` |

Поведение петли (экспорты `engine_*` в `car.gd`):

* до посадки — тишина (`playing == false`), плеер создан и ждёт;
* `enter()` — `play()` с fade-in **0.25 с** (`engine_fade_in`);
* `pitch_scale` **0.85** на холостом ходу → **1.15** на 108 км/ч линейно от
  `get_velocity_kmh() / 108`;
* `volume_db` **−6** в простое → **−2** на полной (плюс кривая фейда);
* `exit()` — fade-out **0.3 с**, затем `stop()`; повторный вход снова поднимает петлю;
* шина **`SFX`**, чтобы ползунок эффектов регулировал двигатель, а не Ambient;
* `AudioStreamPlayer3D`: `unit_size = 6`, `max_distance = 45`,
  `attenuation_model = INVERSE_DISTANCE`, позиция вперёд/вверх от кузова.

**Защита от неготового автолоада.** Если `AudioManager.is_ready() == false`
(бывает при загрузке сохранения), машина не падает и не включает плеер: ждёт
сигнал `audio_ready()` и создаёт петлю после него. Если машину успели занять до
готовности — петля включается сразу после `audio_ready()`; если высадились —
остаётся тихой.

**Выход.** Плеер добавлен в группу `audio_loop_player`; `AudioManager.shutdown()`
глушит такие плееры вместе со своими (явный `playback.stop()`, `stream = null`),
поэтому петля двигателя не оставляет утечек `AudioStreamPlaybackWAV` на выходе.

**Проверка** (отдельная сцена, автолоады поднимаются):

```powershell
tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . `
    tests/car_audio_smoke.tscn --log-file tools\car_audio_smoke.log
```

Ищет `CAR AUDIO SMOKE OK (N проверок)`; проверяет тишину до посадки, `bus == "SFX"`,
pitch 0.85 → 1.15 и громкость −6 → −2 на скорости, `stop` через 0.45 с после
`exit()`, а также сценарий «AudioManager не готов» с ожиданием `audio_ready()`.

Ассеты по-прежнему считает `tools/gen_audio.py` (раздел «Машина»):
`python tools\gen_audio.py --report-only` → «Файлов: 21», `car_door` — тип `sfx`,
`car_engine_loop` — тип `loop`, стык в пределах 1 дБ.
