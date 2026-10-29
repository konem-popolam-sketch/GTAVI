# PHASE 2 — «Ночная смена»: большой патч

Документ-контракт для всех агентов второй фазы. Читать целиком перед работой,
вместе с `docs/GDD.md` и `docs/pipeline.md`.

## Что делаем (запрос пользователя)

1. Починить выход из диалога — **сделано капитаном** (Esc закрывает диалог,
   после закрытия интерактор гаснет на 0.35 с; `scripts/dialogue/dialogue_manager.gd`).
2. Привлечь больше агентов — состав команды `night-shift` расширен.
3. Звук и озвучка.
4. Сильно расширить игру и сюжет.
5. Реалистичнее модели и материалы в целом.

## Железные правила фазы

- **`scenes/main.tscn` — единственный владелец: `godot-specialist` (Рэм), задача t20.**
  Остальные сдают свои сцены/скрипты и в отчёте пишут точные инструкции по вставке
  (узел, родитель, позиция в дереве). Никто, кроме Рэма, не редактирует `scenes/main.tscn`.
- **`project.godot`** правит только `audio-director` (Харуки) — там появляются
  автолоады и шины звука. Остальные просят её в отчёте, если нужен автолоад.
- Никто не коммитит в git, не деплоит, не трогает `.agent-teams`.
- Никто не запускает второй живой экземпляр игры (мост на `127.0.0.1:9090` занят).
  Проверка — headless: `tools\Godot_v4.7.2-stable_win64_console.exe --headless
  --path . --quit-after 300 --log-file tools\<задача>_hl.log` и `--check-only --script`.
- Внешние ассеты — только CC0 (Poly Haven, Kenney), скачивать через Python
  (`urllib.request`), не через curl/Invoke-WebRequest. Файлы кладём в `assets/`.
- PowerShell 5.1 читает UTF-8 без BOM как ANSI: для чтения — `Get-Content -Encoding UTF8`,
  для записи — `Set-Content -Encoding UTF8`.

## Новые каталоги и имена (общий контракт)

```
assets/audio/sfx/            # короткие эффекты
assets/audio/ambience/       # петли окружения (дождь, гул города)
assets/audio/music/          # музыкальные петли
assets/audio/voice/<dialogue_id>_<node_id>.wav   # озвучка реплик
assets/textures/<id>/        # albedo/normal/roughness/ao (2k, CC0)
assets/models/props/         # glTF-пропсы (CC0)
```

- Автолоад `AudioManager` (`scripts/audio/audio_manager.gd`) — единственная точка
  воспроизведения. Публичный API навязываем сразу:
  `play_sfx(name, position = null, volume_db = 0.0)`,
  `play_voice(dialogue_id, node_id) -> bool`,
  `set_bus_volume(bus_name, linear)`, `get_bus_volume(bus_name) -> float`,
  `is_voice_playing() -> bool`, `stop_voice()`.
- Шины звука: `Master`, `Music`, `SFX`, `Voice`, `Ambience`
  (`default_bus_layout.tres` в корне проекта).
- Автолоад `AudioManager` уже прописан в `project.godot`
  (`AudioManager="*res://scripts/audio/audio_manager.gd"`), поднимается до сцены и
  читает громкости из `user://audio.cfg`. Сцене нужны только два узла —
  `Audio` (AmbienceController) и `DialogueAudio`; подробности в `docs/audio/README.md`.
- Громкость по умолчанию: Music −12 dB, SFX −8 dB, Voice −4 dB, Ambience −18 dB
  (t28: дождь мягче и тише, было −14 dB; старый `user://audio.cfg` мигрирует,
  сбрасывается только ambience).

## Схема диалогов v2 (совместима с v1)

Узел диалога: `{speaker, text, next?, choices?, voice_id?, effect?}`.
`voice_id` — ключ в манифесте озвучки; если его нет, озвучка берётся из пары
`<dialogue_id>_<node_id>`. Манифест `scripts/dialogue/data/voice_manifest.json`:

```json
{ "mila": { "mila_01": {"speaker": "Мила", "text": "Нил. Ты снова поздно."} } }
```

Voice-файлы рендерятся офлайн через SAPI (`Microsoft Irina Desktop`, ru-RU) —
скрипт `tools/gen_voice.py`. Озвучка необязательна: если файла или манифеста нет,
диалог идёт как раньше (с субтитрами).

## Кто чем владеет

| Задача | Агент | Файлы (владение) |
| --- | --- | --- |
| t10 сюжет | narrative-director (Тору) | `docs/story_bible.md`, `docs/story_tasks.md` |
| t11 диалоги+манифест | writer (Эми) | `scripts/dialogue/data/*.json` |
| t12 звук | audio-director (Харуки) | `assets/audio/**`, `scripts/audio/**`, `project.godot`, `default_bus_layout.tres` |
| t13 озвучка | sound-designer (Ёко) | `tools/gen_voice.py`, `assets/audio/voice/**` |
| t14 реализм ассетов | art-director (Сакура) | `assets/textures/**`, `assets/models/props/**`, `assets/materials/**` |
| t15 люди вместо капсул | godot-specialist (Рэм) | `scenes/actors/**`, `scenes/player/player.tscn`, `scripts/npc/**` |
| t16 геймплей | gameplay-programmer (Ичиго) | `scripts/game/**`, `scripts/quest/**`, `scenes/objects/**` |
| t17 UI/субтитры/пауза | ui-programmer (Кэйко) | `ui/**`, `scripts/ui/**` |
| t18 новый район | level-designer (Эрен) | `scenes/world/block.tscn`, `scripts/world/world.gd` |
| t19 камера | godot-gdscript-specialist (Тандзиро) | `scripts/player/player.gd` |
| t20 интеграция | godot-specialist (Рэм) | `scenes/main.tscn`, `project.godot` (сведение) |
| t21 приёмка | qa-lead (Мисаки) | `docs/qa/phase2_report.md` |

## Определение готовности фазы 2

1. Headless-прогон `scenes/main.tscn` 600 кадров — exit 0, без `SCRIPT ERROR`.
2. Диалог открывается и закрывается и на E, и на Esc; повторно сам не открывается.
3. Звук: окружение слышно на старте, шаги игрока, звук реплики при диалоге;
   громкость регулируется и сохраняется.
4. Озвучены все реплики основных диалогов (манифест покрывает 100% узлов),
   субтитры совпадают с текстом.
5. Сюжет: минимум 3 акта, 6 персонажей, 3 концовки; квест-лог ведёт по шагам.
6. Материалы и пропсы: на асфальте/кирпиче/металле/дереве видны PBR-текстуры,
   в квартале ≥ 10 пропсов; люди вместо капсул с анимацией ходьбы.
7. Скриншоты до/после в `docs/shots_phase2/`, отчёт QA с числами.
