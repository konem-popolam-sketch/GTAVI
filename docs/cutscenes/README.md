# Катсцены «Ночной смены»: как добавить новую сцену

Система живёт в `scripts/game/cutscene_player.gd` (проигрыватель) и
`scripts/game/cutscene_data.gd` (загрузка JSON). Сцена-обвязка —
`scenes/game/cutscene_stage.tscn`: отдельная `CutsceneCamera`, затемнение,
субтитры и титр. В `scenes/main.tscn` она добавляется одним узлом после `Npcs`
(см. отчёт t38).

## Пять шагов

1. **Создайте JSON** в `scripts/game/cutscenes/`, например `my_scene.json`:

   ```json
   {
     "id": "cut_my_scene",
     "title": "Название для лога",
     "duration": 6.0,
     "skippable": true,
     "seen_flag": "cut_my_scene_seen",
     "fade_in": 0.4,
     "steps": [
       {"t": 0.0, "type": "camera", "pos": [0, 2, 5], "look_at": [0, 1, 0], "fov": 55,
        "to": [0, 2, 4], "duration": 6.0},
       {"t": 1.0, "type": "line", "dialogue_id": "my_dialogue", "node_id": "md_01",
        "speaker": "Нил", "duration": 2.0},
       {"t": 6.0, "type": "end", "player_position": [0, 0.1, 2], "player_yaw": 0.0}
     ]
   }
   ```

2. **Добавьте файл в список** `DATA_FILES` в `scripts/game/cutscene_data.gd`.
   Порядок не важен, id должен быть уникальным.

3. **Текст реплик храните в JSON диалогов** (`scripts/dialogue/data/*.json`):
   шаг `line` ссылается на `dialogue_id` + `node_id`, `speaker` можно не писать —
   он возьмётся из узла/диалога. Пока катсценные диалоги не входят в
   `DialogueData.DATA_FILES`, `CutsceneData` добирает их из
   `voice_manifest.json` (тот же id + узел); inline `text` тоже поддерживается.
   Для озвучки нужен общий JSON — его читает `AudioManager.play_voice`.

4. **Запустите сцену** из своего кода/квеста:
   `CutscenePlayer.start("cut_my_scene")` (или дайте сработать триггеру по флагу
   в `_pick_trigger`). Повторно сцена не играется: `seen_flag` пишется в
   `QuestState` и сохраняется в `user://save.json`.

5. **Проверьте**: `--check-only` нового скрипта, headless-прогон main,
   `tests/cutscene_smoke.tscn` (29 проверок, лог `tools/cutscene_smoke.log`)
   и один живой кадр. Если сцена должна идти после диалога — ставьте флаг
   в диалоге и добавьте правило в `_pick_trigger`; сцена сама дождётся
   `dialogue_ended`.

## Формат шагов

| type | поля | что делает |
|---|---|---|
| `camera` | `pos`, `look_at`, `fov`, `to`, `look_at_to`, `duration`, `ease` | ставит/двигает кат-камеру |
| `player_move` | `from`, `to`, `duration`, `face_movement`, `yaw` | ведёт игрока по точке |
| `line` | `dialogue_id`, `node_id`, `speaker`, `text`, `duration` | субтитр + озвучка через AudioManager |
| `title` | `text`, `duration` | крупный титр |
| `fade` | `alpha`, `duration` | затемнение/выход из чёрного |
| `flash` | `alpha`, `duration` | вспышка (выстрел) |
| `flag` | `flag`, `value` | флаг QuestState |
| `objective` | `text` | цель квеста |
| `item_add` / `item_remove` | `item`, `name` | инвентарь |
| `sfx` | `name`, `position` | звук через AudioManager |
| `npc` | `npc_id`, `visible` | показать/скрыть NPC |
| `npc_move` | `npc_id`, `from`, `to`, `duration` | подвинуть NPC |
| `end` | `player_position`, `player_yaw`, `set_flag`, `remove_item`, `next_dialogue` | финал: позиция, состояние, следующий диалог |

## Правила

- Скип (Esc/Space) пропускает картинку, но **не состояние**: оставшиеся шаги
  `flag`/`objective`/`item_*`/`end` применяются, игрок ставится в конечную точку.
- Пока сцена идёт: управление игрока и интерактор выключены, мышь не захвачена,
  HUD и подписи NPC скрыты, камера игрока не `current`.
- После сцены камера и управление возвращаются; если `QuestState.is_finished()`,
  управление остаётся выключенным — титр концовки показывает HUD.
- Флаг `seen_flag` ставится на старте (автосейв на время сцены выключен) и
  сохраняется на финише; при загрузке сейва сцена не повторяется.
- Не трогайте чужие `scenes/**`, `ui/**`, `scripts/ui/**`; все правки — в
  `scripts/game/cutscenes/` и `scripts/game/cutscene_*.gd`.
