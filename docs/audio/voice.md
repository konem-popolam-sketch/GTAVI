# Озвучка реплик (voice-over)

Офлайн-озвучка всех реплик «Ночной смены» на русском. Сеть не нужна, аудиоустройство
не нужно: синтез идёт локальной нейросетью **piper** (ONNX-веса в `tools/piper/`),
а сборка WAV — `tools/gen_voice_piper.py`.

Имя файла — контракт с игрой: `assets/audio/voice/<dialogue_id>_<node_id>.wav`
(`dialogue_id` и `node_id` — ключи из `scripts/dialogue/data/*.json`).
Сейчас озвучены **26 диалогов, 203 файла из 207 узлов**; 4 узла — немая пауза
«...»/«…» (см. «Что не озвучено»). Суммарную длительность печатает итоговая
строка `python tools\gen_voice_piper.py --force`.

| Параметр | Значение |
| --- | --- |
| Голоса | 4 модели piper: `irina`, `denis`, `dmitri`, `ruslan` + 9 профилей персонажей (питч, темп, эффекты) — таблица в [voices.md](voices.md) |
| Раскладка по моделям | 42 файла irina / 89 denis / 44 dmitri / 28 ruslan |
| Формат | WAV PCM 16 бит, 44.1 кГц, моно |
| Тишина по краям | 60 мс в начале, 120 мс в конце (порог −50 dBFS) |
| Пик | −1 dBFS (у «Голоса в трубке» −4 dBFS: профиль даёт −3 дБ) |
| Импорт в Godot | `.wav.import` есть у всех 203 файлов |

## Быстрый старт

```powershell
# 0) докачать недостающие модели голосов (irina/denis/dmitri/ruslan)
python tools\gen_voice_piper.py --fetch

# 1) что будет сделано, ничего не трогая
python tools\gen_voice_piper.py --dry-run

# 2) досоздать недостающее (существующие файлы не перезаписываются)
python tools\gen_voice_piper.py

# 3) перегенерировать всё (после правок текста или профилей)
python tools\gen_voice_piper.py --force

# 4) только один диалог
python tools\gen_voice_piper.py --only mila_late --force

# 5) импортировать WAV в Godot (обязательно после генерации)
$env:APPDATA="$PWD\.godot_profile"
tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . --import

# 6) проверка: длина/пик/RMS по профилям персонажей
python tools\gen_voice_piper.py --verify
```

Скрипт печатает по строке на реплику (`ok <файл> <сек> <персонаж> <профиль> «текст…»`)
и итог: `создано / пропущено / ошибок; на диске N из M ожидаемых; суммарно X мин речи`.
Код возврата 1 — хотя бы одна реплика не синтезировалась.

## Как это устроено

```
voice_manifest.json ──> gen_voice_piper.py ──> piper.exe ──> trim/normalise ──> 44.1k ──> assets/audio/voice/*.wav
scripts/dialogue/data/*.json ──> gen_voice_manifest.py ──┘                                └──> Godot --import
```

1. `tools/gen_voice_manifest.py` собирает манифест `{dialogue_id: {node_id: {speaker, text}}}`
   из JSON-диалогов. Манифест производный: тексты в нём не могут разойтись с игрой,
   руками его не правят.
2. `gen_voice_piper.py` читает манифест, для каждой пары зовёт
   `tools/piper/piper/piper.exe --model tools/piper/voices/ru_RU-irina-medium.onnx`
   (текст подаётся в stdin, WAV — во временный файл).
3. Постобработка на numpy: обрезка тишины по краям, нормализация пика до −1 dBFS,
   линейный ресэмплинг 22 050 → 44 100 Гц (убирает предупреждение Godot
   `WARN: sample rate 22050 != 44100`).
4. Godot импортирует WAV в `AudioStreamWAV`; `AudioManager.play_voice(dialogue_id, node_id)`
   ищет `voice/<dialogue_id>_<node_id>.wav`, затем запись в манифесте.

Голос выбирается по `speaker` из манифеста через карту `PROFILES` в
`tools/gen_voice_piper.py`: модель piper + темп (`length_scale`) + сдвиг питча
(ресемплинг + OLA-растяжение, длительность сохраняется) + эффект. Полная таблица
персонаж → голос → параметры — в [voices.md](voices.md).

## Манифест

`scripts/dialogue/data/voice_manifest.json`, формат из `docs/PHASE2.md`:

```json
{ "mila": { "mila_01": { "speaker": "Мила", "text": "Нил. Ты сегодня поздно." } } }
```

- ключ верхнего уровня — `dialogue_id`, внутри — `node_id` → `{speaker, text}`;
- `AudioManager` понимает и необязательный `voice_id`/`file`, но генератор кладёт
  файл строго по имени `<dialogue_id>_<node_id>.wav`;
- 4 «диалога» вида `amb_cat`, `amb_bus`, `amb_puddle`, `amb_radio` — это
  сценарные реплики-наблюдения для зон окружения, они тоже озвучены.

## Как добавить или изменить реплику

1. Правка текста — в `scripts/dialogue/data/<dialogue>.json` (владелец — writer).
2. `python tools\gen_voice_manifest.py` — манифест пересобирается из диалогов.
3. `python tools\gen_voice_piper.py` — досоздаст только новые файлы;
   изменившийся текст требует `--force` (или `--only <dialogue_id> --force`).
4. `... --import` в Godot (команда выше).
5. Проверка: `python tools\gen_voice_piper.py --dry-run` — «на диске N из M».

Старые файлы удалённых реплик остаются мусором в `assets/audio/voice/`; их можно
удалить руками — на игру это не влияет.

## Что не озвучено и почему

| узел | причина |
| --- | --- |
| `voice/voice_03`, `cut_box/cb_03`, `cut_weapon/cw_03`, `cut_weapon_alt/cwa_03` | в тексте «...»/«…» — ни одной буквы, это немые паузы персонажей. Синтез дал бы пустой/шумовой файл; в игре остаются субтитры, звук не нужен. |

## Почему не SAPI

Изначально озвучка планировалась через Windows SAPI (`Microsoft Irina Desktop`,
ru-RU). В песочнице DSH это **непроходимо**, проверено на месте:

- `GetInstalledVoices()` видит `Microsoft David Desktop`, `Zira`, `Irina Desktop`,
  токены голосов в HKLM на месте, но `SelectVoice()` падает
  «No voice installed on the system or none available with the current security setting»;
- COM-путь `SAPI.SpVoice` + `SpFileStream` + `AudioOutputStream` + `Speak` даёт
  `0x80045040` при любом `Format.Type` и `0x80045002` без явного формата;
- WinRT `SpeechSynthesizer.AllVoices` → «Internal Speech Error»;
- процесс помечен `Low Mandatory Level` — похоже, SAPI просто не даёт писать звук.

Лог попытки: `tools/gen_voice.log` — 40 строк `FAIL ... 0x80045040`, `created=0`.
Скрипты SAPI (`tools/gen_voice.ps1` + обёртка `tools/gen_voice.py`) оставлены как
рабочий fallback для обычной Windows-машины без песочницы; для сборки игры
используется piper.

`edge-tts` тоже не подошёл: `pip install edge-tts` ставится, но синтез падает
`ServerTimeoutError` (mp3 приходит частично), а это ещё и сеть.

## Ограничения piper

- **Четыре модели на десять спикеров.** Модели: irina, denis, dmitri, ruslan.
  Мила, Галя, «Плёнка» и «Запись» — irina (разный темп и питч, у плёнки эффект),
  Костя и Нил — denis (разный питч и темп), Прораб и Проверяющий — ruslan,
  Тимур и «Голос в трубке» — dmitri (у трубки телефонный эффект). Питч двигается
  в пределах ±10 %, чтобы не было «бурундуков».
- **Интонация ровная.** Нейросеть читает без актёрской игры: сарказм, угроза и
  усталость передаются пунктуацией и короткими фразами, а не голосом.
- **Темп задаётся `length_scale`** (0.92–1.04 от базового); питч-сдвиг делается
  ресемплингом + OLA и длительность не меняет.
- **Ударения и незнакомые слова.** «Сева», «Тимур», «Гриша» читаются верно;
  латиница и аббревиатуры — нет. Лечится переписыванием текста, а не правкой WAV.
- **Кавычки-ёлочки** «Луна» и многоточия не произносятся — это нормально,
  они остаются в субтитрах.
- Вся озвучка — единицы мегабайт (моно 44.1 кГц, ~86 КБ/с).

## Импорт в Godot

WAV в `assets/audio/voice/` требует `.import`-файла, иначе `AudioManager.play_voice()`
вернёт `false`. Импорт — headless, без запуска игры:

```powershell
$env:APPDATA="$PWD\.godot_profile"
tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . --import
```

Успех: в логе `[ DONE ] reimport`, по строке `reimport | <файл>.wav` на каждый файл,
нет `Failed to import`. Шум `Could not create editor cache directory`,
`Failed to read the root certificate store` и `Error saving editor settings to`
— известные ловушки песочницы (`docs/pipeline.md`), их игнорируем.

Проверить, что импорт дошёл: `Get-ChildItem assets\audio\voice\*.wav.import | Measure-Object`
— должно быть 203.

## Интеграция с игрой

Единственная точка воспроизведения — автолоад `AudioManager`
(`scripts/audio/audio_manager.gd`, владелец — Харуки/audio-director):

```gdscript
if AudioManager.play_voice(dialogue_id, node_id):
    pass  # озвучка пошла, субтитры уже показаны
```

Вызов вешается на сигнал `DialogueManager.line_changed(...)` в `DialogueAudio`
(`scripts/audio/dialogue_audio.gd`). Озвучка необязательна: нет файла/манифеста —
диалог идёт только с субтитрами, `play_voice` тихо возвращает `false`.

## Перегенерация после финальных диалогов (t20)

Если Эми правит тексты ещё раз, порядок один и тот же:

```powershell
python tools\gen_voice_manifest.py
python tools\gen_voice_piper.py --force
$env:APPDATA="$PWD\.godot_profile"
tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . --import
Get-ChildItem assets\audio\voice\*.wav | Measure-Object
```
