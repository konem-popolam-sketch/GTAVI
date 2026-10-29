extends Node3D
## Смоук-тест машины (t39). Запуск:
##   & .\tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . tests/car_smoke.tscn --log-file tools/car_smoke_raw.log
## Печатает "CAR SMOKE OK (N проверок)" и выходит с кодом 0, иначе — "CAR SMOKE FAILED".
##
## Тест поднимает настоящий scenes/main.tscn (мир, игрок, автолоады), кладёт рядом
## машину и проверяет посадку, физику, камеру, выход и проезд по маршруту города.

const CAR_SCENE := "res://scenes/vehicles/car.tscn"
const MAIN_SCENE := "res://scenes/main.tscn"
## Точка у гаража из t32 (POI_Garage).
const GARAGE_POINT := Vector3(84.0, 1.4, -58.0)

var _passed: int = 0
var _failed: int = 0
var _lines: PackedStringArray = PackedStringArray()

var _main: Node3D = null
var _player: Node3D = null
var _world: Node3D = null
var _car: VehicleBody3D = null
var _entered_signal: int = 0
var _exited_signal: int = 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _boot()

	_check("машина создана", _car != null and _car is VehicleBody3D)
	_check("машина в группе vehicle", _car.is_in_group("vehicle"))
	_check("машина свободна до посадки", not bool(_car.call("is_occupied")))

	# Кладём машину у гаража и даём подвеске устояться.
	_car.global_position = GARAGE_POINT
	_car.linear_velocity = Vector3.ZERO
	await _wait_physics(90)
	var rest_y: float = _car.global_position.y
	_check("машина стоит на дороге у гаража (y=%.2f)" % rest_y, rest_y > -0.5 and rest_y < 1.5)

	# Для разгона уводим машину на прямой участок кольцевого маршрута:
	# у гаража через 30 м начинается стена, тестировать разгон там бессмысленно.
	var road_ok: bool = _place_on_road(0)
	_check("машина выставлена на маршрут города", road_ok)
	await _wait_physics(30)

	# --- Посадка ---
	var entered_before: int = _entered_signal
	var ok_enter: bool = bool(_car.call("enter", _player))
	await _wait_physics(3)
	_check("enter() вернул true", ok_enter)
	_check("is_occupied() после посадки", bool(_car.call("is_occupied")))
	_check("сигнал entered сработал", _entered_signal == entered_before + 1)
	_check("пешеходное управление отключено", not bool(_player.get("controls_enabled")))

	var interactor: Node = _player.call("get_interactor")
	_check(
		"интерактор игрока отключён",
		interactor != null and not bool(interactor.get("interaction_enabled"))
	)

	var chase: Camera3D = _car.find_child("ChaseCamera", true, false) as Camera3D
	await _wait_time(0.5)
	_check("камера машины стала текущей", chase != null and chase.current)

	# --- Газ (через штатные действия ввода, их читает CarController) ---
	Input.action_press(&"vehicle_accelerate")
	await _wait_physics(120)
	if OS.get_cmdline_user_args().has("--car-debug"):
		_debug_car()
	var speed_after_2s: float = float(_car.call("get_velocity_kmh")) / 3.6
	_check("за 2 с газ даёт > 3 м/с (%.2f м/с)" % speed_after_2s, speed_after_2s > 3.0)

	# --- Ограничение скорости ---
	if OS.get_cmdline_user_args().has("--car-debug"):
		for step in 10:
			await _wait_physics(30)
			print("[car_smoke] drive pos=%s v=%s kmh=%.1f" % [
				_car.global_position, _car.linear_velocity, float(_car.call("get_velocity_kmh"))
			])
	else:
		await _wait_physics(420)
	var speed_max: float = float(_car.call("get_velocity_kmh")) / 3.6
	_check(
		"скорость выходит на предел и не превышает 108 км/ч (%.2f м/с)" % speed_max,
		speed_max <= 31.5 and speed_max > 25.0
	)

	# --- Руль ---
	var yaw_before: float = _car.rotation.y
	Input.action_press(&"vehicle_right")
	await _wait_physics(90)
	Input.action_release(&"vehicle_right")
	var yaw_delta: float = absf(angle_difference(yaw_before, _car.rotation.y))
	_check("руль меняет yaw (%.3f рад)" % yaw_delta, yaw_delta > 0.05)

	# --- Тормоз ---
	Input.action_release(&"vehicle_accelerate")
	Input.action_press(&"vehicle_brake")
	await _wait_physics(150)
	Input.action_release(&"vehicle_brake")
	var speed_braked: float = float(_car.call("get_velocity_kmh"))
	_check("тормоз останавливает (%.1f км/ч)" % speed_braked, speed_braked < 3.0)

	# --- Выход ---
	var exited_before: int = _exited_signal
	var ok_exit: bool = bool(_car.call("exit"))
	await _wait_physics(4)
	_check("exit() вернул true", ok_exit)
	_check("сигнал exited сработал", _exited_signal == exited_before + 1)
	_check("управление игроку вернулось", bool(_player.get("controls_enabled")))
	_check(
		"интерактор игрока снова включён",
		interactor != null and bool(interactor.get("interaction_enabled"))
	)
	var player_y: float = _player.global_position.y
	var door_distance: float = _player.global_position.distance_to(_car.global_position)
	_check(
		"игрок вышел на землю рядом с машиной (y=%.2f, %.1f м)" % [player_y, door_distance],
		player_y >= -0.1 and door_distance < 5.0
	)
	await _wait_time(0.6)
	var player_cam: Camera3D = _player.call("get_camera")
	_check("камера вернулась к игроку", player_cam != null and player_cam.current)

	# --- Машина не уезжает сама ---
	var parked: Vector3 = _car.global_position
	await _wait_physics(90)
	var drift: float = parked.distance_to(_car.global_position)
	_check("машина не уезжает после выхода (%.2f м)" % drift, drift < 0.6)

	# --- Проезд по маршруту города ---
	var route_ok: bool = await _check_route()
	_check("машина не проваливается на маршруте города", route_ok)

	_finish()


# --- Проверка маршрута --------------------------------------------------------


## Ставит машину на перекрёсток внутренней улицы и разворачивает вдоль неё.
## Кольцо get_road_path() идёт по x = ±120 у самой кромки карты — там машина
## упирается в парапет, поэтому для разгона берём перекрёсток (−40, 0, −110).
func _place_on_road(index: int) -> bool:
	if _world == null or not _world.has_method("get_road_path"):
		return false
	var path: PackedVector3Array = _world.call("get_road_path")
	if path.size() < 4:
		return false
	var point := Vector3(-40.0, 0.0, -110.0)
	var direction := Vector3(0.0, 0.0, -1.0)
	if index > 0:
		var i: int = clampi(index, 0, path.size() - 2)
		point = path[i]
		direction = path[i + 1] - point
		direction.y = 0.0
		if direction.length() < 0.01:
			direction = Vector3(0.0, 0.0, -1.0)
	direction = direction.normalized()
	_car.global_position = point + Vector3.UP * 0.8
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	# Перед машины (её +Z: так её ведёт VehicleWheel3D) смотрит вдоль дороги.
	_car.rotation.y = atan2(direction.x, direction.z)
	return true


func _check_route() -> bool:
	if _world == null or not _world.has_method("get_road_path"):
		_lines.append("  ! у мира нет get_road_path() — маршрут не проверен")
		return false
	var path: PackedVector3Array = _world.call("get_road_path")
	if path.size() < 8:
		_lines.append("  ! маршрут короче 8 точек (%d)" % path.size())
		return false
	var samples: int = 6
	var ok: bool = true
	for i in samples:
		var index: int = int(round(float(i) * float(path.size() - 1) / float(samples - 1)))
		var point: Vector3 = path[index]
		_car.global_position = point + Vector3.UP * 1.2
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO
		await _wait_physics(45)
		var car_y: float = _car.global_position.y
		var fell: bool = car_y < point.y - 1.0 or car_y != car_y
		if fell:
			ok = false
			_lines.append("  ! на точке %d (%.1f, %.1f, %.1f) машина ушла на y=%.2f"
				% [index, point.x, point.y, point.z, car_y])
	return ok


# --- Инфраструктура -----------------------------------------------------------


func _boot() -> void:
	var main_scene: PackedScene = load(MAIN_SCENE)
	_main = main_scene.instantiate() as Node3D
	add_child(_main)
	await _wait_physics(6)

	_player = _main.get_node_or_null("Player") as Node3D
	_world = _main.get_node_or_null("World")
	if _main.has_method("start_fresh"):
		_main.call("start_fresh")
	await _wait_physics(6)

	var car_scene: PackedScene = load(CAR_SCENE)
	_car = car_scene.instantiate() as VehicleBody3D
	_main.add_child(_car)
	await _wait_physics(2)
	_car.entered.connect(_on_entered)
	_car.exited.connect(_on_exited)


func _on_entered(_player_node: Node3D) -> void:
	_entered_signal += 1

func _on_exited(_player_node: Node3D) -> void:
	_exited_signal += 1


func _debug_car() -> void:
	print("[car_smoke] debug: pos=%s engine_force=%.1f brake=%.1f steer=%.3f mass=%.0f throttle=%.2f"
		% [_car.global_position, _car.engine_force, _car.brake, _car.steering, _car.mass,
			float(_car.get("_throttle"))])
	for wheel_name in ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]:
		var wheel: VehicleWheel3D = _car.get_node_or_null(wheel_name)
		if wheel == null:
			print("   %s: нет узла" % wheel_name)
			continue
		print("   %s тракция=%s руль=%s контакт=%s" % [
			wheel_name, wheel.use_as_traction, wheel.use_as_steering, wheel.is_in_contact()
		])


func _wait_physics(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame


func _wait_time(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _check(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		_lines.append("  ok   " + label)
	else:
		_failed += 1
		_lines.append("  FAIL " + label)


func _finish() -> void:
	print("[car_smoke] --- результаты ---")
	for line in _lines:
		print(line)
	if _failed == 0:
		print("CAR SMOKE OK (%d проверок)" % _passed)
		get_tree().quit(0)
	else:
		print("CAR SMOKE FAILED (%d провалено из %d)" % [_failed, _passed + _failed])
		get_tree().quit(1)
