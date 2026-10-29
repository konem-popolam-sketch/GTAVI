extends Node
## Sprint smoke: Shift даёт бег (8.5 м/с против 4.0 м/с), камера расширяет FOV,
## корпус наклоняется вперёд, а без Shift игрок снова идёт шагом.
##
## Запуск:
##   tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . tests/sprint_smoke.tscn
## Успех: код 0 и строка "SPRINT SMOKE OK".

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const OK_MARKER := "SPRINT SMOKE OK"
const WALK_LIMIT := 4.4
const RUN_LIMIT_MIN := 7.8
const RUN_LIMIT_MAX := 9.0
const FOV_MIN_GAIN := 2.0
const LEAN_MIN_DEGREES := 2.0

var _failures: Array[String] = []
var _checks: int = 0
var _player: Player = null
var _camera: Camera3D = null
var _fov_base: float = 70.0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== SPRINT SMOKE START ===")
	await get_tree().process_frame
	_build_floor()
	_player = (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
	_player.position = Vector3(0.0, 0.1, 0.0)
	add_child(_player)
	_camera = _player.get_camera()
	await _wait_physics_frames(5)
	_fov_base = _camera.fov

	_check_binding()
	await _check_events()
	await _check_walk()
	await _check_run()
	await _check_feedback()
	await _check_stand_with_shift()
	await _check_back_to_walk()
	_finish()


# --- Проверки ---------------------------------------------------------------


func _check_binding() -> void:
	_expect(InputMap.has_action("run"), "в InputMap нет действия run")
	var has_shift := false
	for event in InputMap.action_get_events("run"):
		if event is InputEventKey:
			var key := event as InputEventKey
			if key.keycode == KEY_SHIFT or key.physical_keycode == KEY_SHIFT:
				has_shift = true
	_expect(has_shift, "действие run не привязано к Shift")


func _check_events() -> void:
	# Событие без флага shift_pressed — так клавиша Shift иногда приходит от
	# платформы. Действие не должно требовать этот модификатор.
	_send_key(KEY_SHIFT, true, false)
	await _settle_input()
	_expect(Input.is_action_pressed("run"), "Shift без флага shift_pressed не активирует run")
	_send_key(KEY_SHIFT, false, false)
	await _settle_input()
	_expect(not Input.is_action_pressed("run"), "отпускание Shift не гасит run")
	# И событие с флагом тоже должно работать (Shift + другая клавиша).
	_send_key(KEY_SHIFT, true, true)
	await _settle_input()
	_expect(Input.is_action_pressed("run"), "Shift с флагом shift_pressed не активирует run")
	_send_key(KEY_SHIFT, false, true)
	await _settle_input()
	_expect(not Input.is_action_pressed("run"), "отпускание Shift с флагом не гасит run")


func _check_walk() -> void:
	_release_all()
	_send_key(KEY_W, true)
	await _wait_physics_frames(60)
	_player.rotation.y = 0.0
	var speed := _speed()
	_expect(speed > 0.5, "игрок не поехал по W (%.2f м/с)" % speed)
	_expect(speed <= WALK_LIMIT, "без Shift скорость выше шага: %.2f м/с" % speed)
	print("[walk] %.2f м/с" % speed)


func _check_run() -> void:
	# Shift без флага модификатора — самый частый реальный случай.
	_send_key(KEY_SHIFT, true, false)
	await _wait_physics_frames(60)
	var speed := _speed()
	_expect(
		speed >= RUN_LIMIT_MIN and speed <= RUN_LIMIT_MAX,
		"с Shift скорость не стала беговой: %.2f м/с" % speed
	)
	var animation: String = _player.body_mesh.get_current_animation()
	_expect(animation == "run", "на бегу играет анимация '%s', а не 'run'" % animation)
	print("[run] %.2f м/с (run_speed=%.2f), анимация '%s'" % [speed, _player.run_speed, animation])


func _check_feedback() -> void:
	var fov_gain := _camera.fov - _fov_base
	_expect(fov_gain >= FOV_MIN_GAIN, "FOV не расширился на бегу (%.2f°)" % fov_gain)
	var lean := rad_to_deg(_player.body_mesh.rotation.x)
	_expect(
		lean <= -LEAN_MIN_DEGREES,
		"корпус не наклонился вперёд на бегу (%.2f°)" % lean
	)
	print("[feedback] FOV +%.2f°, наклон %.2f°" % [fov_gain, lean])


func _check_stand_with_shift() -> void:
	_release_all()
	_send_key(KEY_SHIFT, true, true)
	await _wait_physics_frames(45)
	var speed := _speed()
	var fov_gain := _camera.fov - _fov_base
	var lean := rad_to_deg(_player.body_mesh.rotation.x)
	_expect(speed < 0.3, "стоя на месте игрок всё равно едет: %.2f м/с" % speed)
	_expect(absf(fov_gain) < 0.5, "Shift без движения расширяет FOV: %.2f°" % fov_gain)
	_expect(absf(lean) < 0.5, "Shift без движения наклоняет корпус: %.2f°" % lean)
	_send_key(KEY_SHIFT, false, false)
	await _wait_physics_frames(10)


func _check_back_to_walk() -> void:
	_release_all()
	_send_key(KEY_W, true)
	await _wait_physics_frames(60)
	var speed := _speed()
	_expect(speed <= WALK_LIMIT, "после отпускания Shift скорость не упала: %.2f м/с" % speed)
	var fov_gain := _camera.fov - _fov_base
	_expect(absf(fov_gain) < 0.5, "FOV не вернулся после бега: %.2f°" % fov_gain)
	_release_all()
	await _wait_physics_frames(5)
	print("[walk back] %.2f м/с, FOV %.1f" % [speed, _camera.fov])


# --- Утилиты ----------------------------------------------------------------


func _build_floor() -> void:
	var body := StaticBody3D.new()
	body.name = "SmokeFloor"
	body.collision_layer = 1
	body.collision_mask = 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(120.0, 0.5, 120.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.25, 0.0)
	body.add_child(shape)
	add_child(body)


func _speed() -> float:
	return Vector2(_player.velocity.x, _player.velocity.z).length()


func _send_key(code: int, pressed: bool, with_shift: bool = false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	event.shift_pressed = with_shift
	Input.parse_input_event(event)


func _release_all() -> void:
	for code in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_SHIFT]:
		_send_key(code, false)
	Input.flush_buffered_events()


func _wait_physics_frames(count: int) -> void:
	for _frame in count:
		await get_tree().physics_frame


## Событие из parse_input_event приходит в следующем кадре: ждём и кадр, и
## физику, чтобы Input уже обновил состояние действия.
func _settle_input() -> void:
	Input.flush_buffered_events()
	await get_tree().process_frame
	await get_tree().physics_frame


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures.append(message)
	print("[FAIL] %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("%s (проверок: %d)" % [OK_MARKER, _checks])
		get_tree().quit(0)
		return
	print("SPRINT SMOKE FAILED: %d из %d" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - %s" % failure)
	get_tree().quit(1)
