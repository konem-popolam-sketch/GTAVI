# Огнестрельное оружие «Ночной смены» — пистолет (t30; сохранение патронов — t51)

Пистолет как игровой предмет и боевая механика без сюжетной ветки: подбор с
прилавка, кобура/руки, хитскан из камеры, магазин и запас, перезарядка,
вспышка/трассер и сигналы для HUD. Всё сделано отдельными файлами; `player.gd`,
`scenes/player/**`, `scenes/main.tscn` и UI не менялись.

## Файлы

| Файл | Что это |
| --- | --- |
| `scenes/objects/pistol.tscn` | модель пистолета из примитивов (затвор, ствол, рамка, рукоять, целик), `PickupArea` (Area3D) и `Muzzle` с вспышкой |
| `scripts/game/weapon.gd` | `class_name Weapon`, группа `weapon`: состояния, патроны, хитскан, звук, сигналы |
| `scripts/game/weapon_controller.gd` | `class_name WeaponController`, отдельный узел под Player: ввод F/ЛКМ/R и блокировки |
| `scenes/objects/projectile.tscn` + `scripts/game/projectile.gd` | короткоживущий визуальный трассер (0.08 с), не баллистика |
| `tests/weapon_smoke.tscn` + `tests/weapon_smoke.gd` | смоук на 46 проверок (включая save/load патронов и мусор в item_state), лог `tools/t51_weapon_smoke.log`, строка `WEAPON SMOKE OK` |
| `scripts/game/save_system.gd` | перед записью собирает ammo/reserve оружия в `quest.item_states`, после загрузки раздаёт их обратно; формат сейва не менялся |
| `project.godot` | добавлены действия `weapon_toggle` (F), `fire` (ЛКМ), `reload` (R); старые действия не тронуты |

## Управление

| Клавиша | Действие |
| --- | --- |
| `E` | подобрать пистолет, лежащий в мире (через существующий `Interactor`) |
| `F` (`weapon_toggle`) | достать / убрать пистолет |
| ЛКМ (`fire`) | выстрел (хитскан) |
| `R` (`reload`) | перезарядка |

Стрельба/перезарядка/доставание блокируются, пока открыт диалог
(`DialogueManager.is_active()`), открыта пауза (`get_tree().paused` или
`PauseMenu.is_open()`), висит титульная плашка (группа `title_card`) или у
игрока выключено управление (`Player.controls_enabled == false`).

## Числа (все — экспорт-поля Weapon, можно менять в инспекторе)

| Параметр | Значение |
| --- | --- |
| Магазин | 8 патронов |
| Запас | 24 патрона |
| Перезарядка | 1.6 с |
| Интервал между выстрелами | 0.35 с |
| Разброс в движении | 1.2° |
| Разброс стоя | 0.3° |
| Урон | 25 |
| Дальность луча | 120 м |
| Маска мира | слой 1 (`world_collision_mask`) |
| Вспышка | 0.05 с |
| Трассер | 0.08 с |

Стрельба — хитскан `PhysicsRayQueryParameters3D` из **камеры** игрока, не из
ствола. Собственное тело игрока исключается через `query.exclude` (в Godot 4
`exclude` нужно присваивать массивом, а не делать `append` у getter-копии).
Ствол нужен только для позиции вспышки/трассера.

## API Weapon

Состояния: `holstered` (убран), `equipped` (в руках), `reloading` (перезарядка).

```gdscript
pickup(player: Node3D = null) -> bool   # взять с прилавка/земли
equip() -> bool; holster() -> bool
can_fire() -> bool
fire() -> bool                          # хитскан; false если кулдаун/нет патронов
reload() -> bool                        # запускает перезарядку на 1.6 с
is_owned(); is_equipped(); is_reloading(); get_state() -> String
get_current_ammo() -> int; get_reserve_ammo() -> int
get_owner_player() -> Node3D; get_muzzle_position() -> Vector3
get_item_id() -> String                  # "pistol"
get_item_state() -> Dictionary           # {"ammo": int, "reserve": int}
apply_item_state(state: Dictionary)      # восстановление после сейва/спавна/подбора
interact(player)                        # E по лежащему пистолету = pickup
```

Сигналы:

```gdscript
fired(from: Vector3, to: Vector3)         # from — камера, to — попадание/конец луча
ammo_changed(current: int, reserve: int)
reloaded()
hit_target(target: Node, position: Vector3, damage: float)
picked_up(weapon: Weapon, player: Node3D)
state_changed(state: String)
equipped_changed(equipped: bool)
```

`hit_target` приходит для NPC (группа `npc`) и объектов с `meta damageable=true`;
мир (стены/пол) сигнал не даёт. На попадании в NPC коротко (0.12 с) вспыхивает
его `Highlight` OmniLight, если он есть; анимации смерти/реакции нет — это
отдельная задача.

## API WeaponController

Узел-компаньон, `player.gd` не нужен. Сам находит `Player` по группе `player`,
пистолет — по группе `weapon` (или `weapon_path`).

```gdscript
try_toggle() -> bool; try_fire() -> bool; try_reload() -> bool
is_blocked() -> bool
has_weapon() -> bool; get_weapon() -> Weapon; is_weapon_equipped() -> bool
```

## Сохранение патронов

`SaveSystem.save_game()` перед записью читает `get_item_state()` у всех узлов
группы `weapon` и кладёт результат в `quest.item_states[<item_id>]` (для
пистолета — `"pistol": {"ammo": 7, "reserve": 24}`). Формат `save.json` не менялся.

`SaveSystem.load_game()` после `QuestState.from_dict()` вызывает
`apply_item_state()` у оружия; кроме того, `Weapon._ready()` и `Weapon.pickup()`
сами подхватывают состояние из `QuestState.item_states`, если узел появился позже
сейва. Валидация в `apply_item_state()`:

- `ammo` клампится в `0…magazine_size`;
- `reserve` клампится в `0…999`;
- нечисловые значения игнорируются по полю с предупреждением
  `[weapon] item_state проигнорирован: ammo=…`.

Проверено в `tests/weapon_smoke.tscn`: `3/11 → save → load → 3/11`,
`999/-5 → 8/0`, строковый мусор не падает и не меняет патроны. Дополнительно
проверено на `scenes/main.tscn`: сейв с `item_states.pistol {ammo:3, reserve:11}`
загружается и после `--save-now` остаётся `3/11`.

## Интеграция в main.tscn (задача t20/интегратора)

1. Добавить экземпляр `scenes/objects/pistol.tscn` в `Main` (не в `Player`) на
   прилавок у «Луны». Ориентир: Package стоит в `(-4.6, 0.21, -11.0)`;
   пистолет предлагается в `(-5.0, 0.22, -10.7)`, `rotation.y ≈ 0.4`.
   Если у прилавка появится высота — поднять `y` до его поверхности.
2. Добавить `WeaponController` (Node со скриптом
   `scripts/game/weapon_controller.gd`) ребёнком `Player`:
   `Player/WeaponController`. Больше ничего не требуется: контроллер сам
   найдёт игрока и пистолет, ввод — через действия `weapon_toggle`/`fire`/`reload`.
3. HUD патронов делает Кэйко отдельной задачей; здесь только сигналы. Никаких
   правок `ui/**` и `scripts/ui/**` не требуется.

## Что ждём от звукового отдела (Харуки/Ёко)

Имена SFX (положить в `assets/audio/sfx/` как `.wav`/`.ogg`):

| Имя | Когда |
| --- | --- |
| `pistol_fire` | каждый выстрел |
| `pistol_reload` | начало перезарядки |
| `pistol_empty` | попытка выстрела с пустым магазином |

Пока файлов нет, Weapon вызывает `AudioManager.get_stream(name, "sfx", false)`;
если null — тихо пропускает вызов `play_sfx`, без warning'ов и падений. Когда
файлы появятся, менять код не нужно.

## Что ждём от HUD (Кэйко)

Подключиться к `Weapon` (найти по группе `weapon` или через WeaponController) и
использовать `ammo_changed(current, reserve)` + `state_changed(state)`:

- `current` — патроны в магазине (0…8), `reserve` — запас;
- `state` — `holstered` / `equipped` / `reloading`;
- `reloaded` — конец перезарядки; `fired` — выстрел; `hit_target` — попадание по
  NPC (если понадобится маркер попадания).

## Проверка

```powershell
tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . tests/weapon_smoke.tscn
# успех: WEAPON SMOKE OK (46 проверок), exit 0, tools/t51_weapon_smoke.log

tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . --quit-after 120 --log-file tools\t51_hl.log
# успех: exit 0, без SCRIPT ERROR
```

Смоук проверяет: действия в InputMap, подбор, повторный подбор, equip, стартовые
8/24, выстрел и убыль патрона, сигнал `fired`, попадание в коллайдер и
`hit_target`, кулдаун, пустой магазин, перезарядку (8/16 после 1.6 с), holster/
equip, блокировку выстрела при открытом диалоге, save/load патронов (3/11 → 3/11)
и клампинг мусора (999/-5 → 8/0).

## Ограничения

- Нет HUD патронов, анимаций перезарядки/смерти, отдачи и прицеливания (ADS) —
  отдельные задачи.
- Смоук гоняется на синтетической сцене; в `main.tscn` пистолет и контроллер
  появляются только после шага интеграции выше.
- Ничего не коммитилось и не деплоилось.
