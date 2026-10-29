# Машина (t39): `scenes/vehicles/car.tscn`

Ночной квартал + город 360×358 м (t32) — пешком долго, поэтому у гаража стоит машина:
`VehicleBody3D` из примитивов, без внешних ассетов.

```
Car (VehicleBody3D, группа "vehicle", mass 1200)
├── CollisionShape3D            BoxShape3D 1.86 × 0.62 × 4.0
├── Body                        визуал: Chassis, Cabin, Roof, Windshield, Hood, Trunk,
│                               бамперы, HeadLampL/R, TailLampL/R, TailGlow
├── HeadLightL / HeadLightR     SpotLight3D, тёплый 30 м, 26°, тени выключены (цена кадра)
├── WheelFL / WheelFR           VehicleWheel3D r 0.34, use_as_steering
├── WheelRL / WheelRR           VehicleWheel3D r 0.34, use_as_traction (задний привод)
├── Seat                        Node3D (точка водителя, x +0.36 — левый руль)
├── CameraAnchor → ChaseCamera  Camera3D, fov 68, вид сзади-сверху
├── EnterArea (Area3D)          scripts/game/vehicle_enter.gd — «E — сесть за руль»
└── Controller (Node)           scripts/vehicles/car_controller.gd — ввод, камера, выход
```

## Важно: перед машины — её **+Z**

`VehicleWheel3D` в Godot 4.7 толкает кузов вдоль **+Z** локальной оси (проверено замером:
`engine_force = 2600` при `rotation.y = 0` → `delta.z = +4.6 м` за 1.5 с). Поэтому фары,
капот и лобовое стекло стоят на `z > 0`, а задние габариты и камера — на `z < 0`.
Из этого же следует инверсия знака руля в контроллере: «вправо» (D) = поворот к `−X`.

## Числа

| Параметр | Значение | Где |
| --- | --- | --- |
| Масса | 1200 кг | `Car.mass` |
| Центр тяжести | `(0, −0.25, 0)` от центра кузова | `center_of_mass_mode = CUSTOM` в `car.gd::_ready` |
| Тяга | 2600 Н на заднюю ось | `max_engine_force` |
| Тормоз / ручник | 22 / 45 | `brake_force`, `handbrake_force` |
| Максимум | 108 км/ч (30 м/с) | `max_speed_kmh` |
| Руль | 34°, скорость 2.6 рад/с, возврат 6 рад/с | `steering_max_deg`, `steering_speed`, `steering_return_speed` |
| Колёса | r 0.34, rest length 0.12, stiffness 45, damping 1.6/2.4 | `car.tscn` |
| Накат | гасится 0.35/с, когда газ и тормоз отпущены | `rolling_resistance` |

Замеры смоука: 0 → 7.65 м/с за 2 с, 25.6 м/с на 7-й секунде (предел не превышен),
тормоз с ~25 м/с останавливает до 0.1 км/ч, посадка машины на дорогу — `y ≈ −0.09`.

## API машины (`scripts/vehicles/car.gd`, `class_name Car`)

```gdscript
car.enter(player) -> bool         # посадить; отключает управление игрока, включает камеру машины
car.exit(player = null) -> bool   # высадить рядом с дверью, вернуть управление и камеру
car.is_occupied() -> bool
car.get_velocity_kmh() -> float
car.set_drive_input(throttle, steer, brake, handbrake)  # для ИИ/тестов, минуя клавиатуру
car.release_drive_input()
signal entered(player)
signal exited(player)
```

`enter()`/`exit()` сами зовут `Controller.attach()/detach()` — всё, что делает контроллер
(ввод, камера, скрытие игрока), происходит из них. Если контроллера в сцене нет, машина
остаётся катящейся бочкой без управления и пишет `push_warning`.

## Ввод (`scripts/vehicles/car_controller.gd`)

`project.godot` не тронут: шесть действий создаются в рантайме в `_ready()`, если их нет.

| Действие | Клавиши |
| --- | --- |
| `vehicle_accelerate` | W, ↑ |
| `vehicle_brake` | S, ↓ |
| `vehicle_left` / `vehicle_right` | A / D, ← / → |
| `vehicle_handbrake` | Space |
| `vehicle_boost` | Shift (газ в пол) |
| выход | `interact` (E), с кулдауном 0.35 с после посадки |

Пока игрок в машине: `player.set_controls_enabled(false)`, интерактор выключен,
игрок скрыт и его коллизия отключена (`set_physics_process(false)`, `shape.disabled = true`) —
капсула не толкает кузов и не торчит из крыши. Камера: `ChaseCamera` перелетает из
текущего положения камеры игрока за 0.4 с (Tween SINE) и дальше жёстко приклеена к машине;
при выходе — обратный перелёт, `player.get_camera().current = true`.

Выход: точка справа/слева/сзади от машины проецируется на землю лучом, затем проверяется,
что над точкой есть 1.9 м под капсулу игрока; найденная точка отдаётся в
`player.teleport_to()`. Машина после `exit()` получает `engine_force = 0` и
`brake = brake_force` — сама не уезжает (проверено: 0.00 м дрейфа за 1.5 с).

## Точка входа (`scripts/game/vehicle_enter.gd`)

`Area3D` 2.6 × 2.2 × 5.4 вокруг кузова, `collision_layer = 1`. Реализует
`get_interact_hint() -> "E — сесть за руль"` и `interact(player)`. HUD подсказку рисует сам
(`scripts/ui/hud.gd::_hint_for_target`), мета `interactable = true` ставится в `_ready()`.

## Как подключить к `scenes/main.tscn` (делает интегратор)

`main.tscn` в этой задаче не трогался. Нужно:

1. `[ext_resource type="PackedScene" path="res://scenes/vehicles/car.tscn" id="N_car"]`.
2. Инстанс ребёнком `Main` (рядом с `Player`), имя `PlayerCar`:

```
[node name="PlayerCar" parent="." instance=ExtResource("N_car")]
transform = Transform3D(-1, 0, 0, 0, 1, 0, 0, 0, -1, 120, 0.2, -58)
```

`x = 120, z = −58` — проезжая часть кольца в 36 м от гаража (`POI_Garage` = `84, 0.15, −58`);
`rotation.y = π` ставит нос вдоль улицы на север. Машина сама осядет на дорогу (`y ≈ −0.09`),
поэтому стартовать можно с `y = 0.2…1.2`. Если хочется «у самых ворот», координаты
`(84, 0.2, −58)` тоже держат (`y ≈ −0.10`), но там тротуарная плита.

Больше ничего не требуется: NPC, диалоги и квест машину не замечают, `Player` не меняется.

## Чего ждём от звука (`scripts/audio/**`)

- `car_engine_loop` — петля двигателя, тон/громкость от `get_velocity_kmh()`.
- `car_door` — открытие/закрытие двери (уже вызывается из `Car.enter()/exit()` через
  `AudioManager.play_sfx("car_door", global_position)`; пока файла нет — тихий no-op,
  в логе `[audio]` может быть warning).

`car.gd::_update_engine_audio()` — заготовка под петлю: сейчас пустая, потому что у
`AudioManager` нет API петель (см. docs/audio/README.md).

## Проверки

```powershell
$env:APPDATA = "C:\Users\Igor\Downloads\GTAVI\.tmp_appdata"
$env:LOCALAPPDATA = "C:\Users\Igor\Downloads\GTAVI\.tmp_appdata\Local"
# смоук (23 проверки, строка "CAR SMOKE OK")
& .\tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . tests/car_smoke.tscn --log-file tools/car_smoke.log
# дерево целиком
& .\tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . --quit-after 600 --log-file tools/car_hl.log
```

Смоук поднимает настоящий `scenes/main.tscn`, кладёт машину у гаража, проверяет посадку
(управление/интерактор/камера), разгон, предел скорости, руль, тормоз, выход (игрок на земле,
управление вернулось, машина не уезжает) и проезд по шести точкам `World.get_road_path()`
без проваливания. Для разгона машина выставляется на перекрёсток `(−40, 0, −110)`: кольцо
`get_road_path()` идёт по `x = ±120` у самой кромки карты, там машина упирается в парапет.

Кадры: `docs/shots_car/{00_overview,01_car_at_garage,02_cockpit_drive,03_car_on_street}.png`
(живой инстанс на мосту 9091, свободная камера; в кадре из кабины крыша и лобовое стекло
скрыты рантаймом, иначе камера внутри бокса кузова).
