# Конвейер проверки (читать до первого коммита кода)

Движок: `tools\Godot_v4.7.2-stable_win64.exe` (4.7.2 stable, Forward+).
Всё, что ниже, проверено в этой сессии — не изобретай другие способы.

## 1. Живой мост уже запущен

Игра сейчас работает в отдельном окне и держит TCP-порт `127.0.0.1:9090` (автолоад
`autoload/mcp_interaction_server.gd`). Клиент — `tools/bridge.py`:

```powershell
python tools\bridge.py info                    # связь есть?
python tools\bridge.py eval "return get_tree().current_scene.name"   # код в живой игре
python tools\bridge.py tree                    # дерево сцены
python tools\bridge.py shot docs\shot_01.png   # скриншот в файл (потом открой его!)
python tools\bridge.py cmd <command> '<json>'   # любой сырой вызов
```

Команды сервера плоские: `{"command":"eval","params":{"code":"..."}}`, `screenshot`,
`get_scene_tree`, `get_property`, `set_property`, `call_method`, `raycast`, `click`,
`key_press`, `spawn_node`, `change_scene`, `serialize_state` и ещё ~70 — полный список в
`autoload/mcp_interaction_server.gd` (таблица диспетчера).

**Важно:** изменение сцены/скрипта на диске НЕ подхватывается живой игрой. После правки
нужен перезапуск игры (попроси капитана) либо проверка через headless (ниже).

## 2. Headless-проверка (быстрая, без окна)

```powershell
& .\tools\Godot_v4.7.2-stable_win64.exe --headless --path . --quit-after 300 --log-file tools\hl.log
Get-Content tools\hl.log
```

`--quit-after N` = N кадров. Скриптовые ошибки видны в `tools\hl.log` строками `ERROR`/`SCRIPT ERROR`.
Код возврата 0 ничего не значит — смотри лог.

Проверка синтаксиса одного скрипта:

```powershell
& .\tools\Godot_v4.7.2-stable_win64.exe --headless --path . --check-only --script res://scripts/player/player.gd --log-file tools\hl.log
```

## 3. Известные ловушки песочницы

- `ERROR: Could not create directory: 'user://logs'` и `user://vulkan` — **нормально**, это запрет
  записи в `%APPDATA%\Godot`. Игра всё равно работает. Не «лечи».
- `ERROR: Failed to read the root certificate store` — тоже шум, игнорируй.
- **Не запускай второй экземпляр игры**: порт 9090 занят, новый экземпляр поднимет 9091 и
  `bridge.py` не увидит его. Для проверки диска — только headless или ждать разрешения капитана.
- Не трогай `autoload/mcp_interaction_server.gd` — это инфраструктура, не часть игры.
- Никаких git-коммитов, никаких деплоев. Только файлы проекта.

## 4. Скриншот — обязательный шаг

«Работает» подтверждается картинкой: `python tools\bridge.py shot docs\shot_NN.png` и просмотром
файла. Серый прямоугольник без геометрии = не работает.

## 5. После правки миров/сцен — ОБЯЗАТЕЛЬНЫЙ рестарт окна

Это стоило трёх кругов правок в фазе 3, поэтому правило жёсткое:

1. сначала headless-прогон (`--quit-after 300/600`) на **новом** файле;
2. затем рестарт живого окна: убить `Godot*`, поднять заново
   (`APPDATA=.godot_profile`, `--log-file tools\live_N.log`);
3. **только после этого** снимать кадры `tools/shot_cam.py`.

Если снять кадры со старого окна, увидишь предыдущую версию сцены и будешь «чинить» то, что уже
исправлено. Признак этой ошибки: кадры байт-в-байт похожи на прошлые, хотя правки внесены.

## 6. Раскладка скриншотов по фазам

| Папка | Что внутри |
| --- | --- |
| `docs/shots_phase2/`, `docs/shots_final/` | сборка фазы 2 |
| `docs/shots_t24`…`docs/shots_t49/` | кадры по номерам задач |
| `docs/shots_live/` | снимки живого окна, которое видит пользователь |

Не сваливай всё в одну папку: по имени папки сразу видно, к какой задаче относится кадр.

