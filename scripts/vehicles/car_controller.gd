extends Node
## Ввод игрока, пока он за рулём, и переключение камеры.
##
## Живёт дочерним узлом машины (Car/Controller). Машина сама зовёт
## attach(player) / detach(player) из своего enter()/exit().
##
## Клавиши: WASD или стрелки — газ/тормоз/руль, Space — ручник,
## Shift — газ в пол, E — выйти из машины.
## Новые действия InputMap создаются здесь же в рантайме (project.godot не трогаем).

const ACTION_ACCEL: StringName = &"vehicle_accelerate"
const ACTION_BRAKE: StringName = &"vehicle_brake"
const ACTION_LEFT: StringName = &"vehicle_left"
const ACTION_RIGHT: StringName = &"vehicle_right"
const ACTION_HANDBRAKE: StringName = &"vehicle_handbrake"
const ACTION_BOOST: StringName = &"vehicle_boost"

## Плавность перехода камеры, с.
@export var camera_blend_time: float = 0.4
## Пауза после посадки, чтобы то же нажатие E не высадило сразу.
@export var exit_cooldown: float = 0.35
## Смещение точки выхода относительно машины (вправо от кузова).
@export var door_offset: Vector3 = Vector3(1.7, 0.0, 0.1)

var _car: VehicleBody3D = null
var _player: Node3D = null
var _player_shapes: Array[CollisionShape3D] = []
var _chase_local: Transform3D = Transform3D.IDENTITY
var _chase_camera: Camera3D = null
var _cooldown: float = 0.0
var _tween: Tween = null
var _driving: bool = false


func _ready() -> void:
	_car = get_parent() as VehicleBody3D
	_chase_camera = _car.find_child("ChaseCamera", true, false) as Camera3D if _car != null else null
	if _chase_camera != null:
		_chase_local = _chase_camera.transform
	_ensure_input_actions()
	set_physics_process(false)


func _physics_process(delta: float) -> void:
	if not _driving or _car == null:
		return
	if _cooldown > 0.0:
		_cooldown -= delta

	var throttle: float = Input.get_action_strength(ACTION_ACCEL)
	var brake_input: float = Input.get_action_strength(ACTION_BRAKE)
	# Перед машины — её +Z, поэтому «вправо» (D) — это поворот к −X: знак обратный.
	var steer: float = Input.get_action_strength(ACTION_LEFT) - Input.get_action_strength(ACTION_RIGHT)
	var handbrake: bool = Input.is_action_pressed(ACTION_HANDBRAKE)
	if Input.is_action_pressed(ACTION_BOOST):
		throttle = 1.0

	_car.set_drive_input(throttle, steer, brake_input, handbrake)

	if _cooldown <= 0.0 and Input.is_action_just_pressed(&"interact"):
		request_exit()


# --- Вызывается машиной ------------------------------------------------------


func attach(player: Node3D) -> void:
	if player == null or _car == null:
		return
	_player = player
	_driving = true
	_cooldown = exit_cooldown
	_car.release_drive_input()

	_capture_player_shapes()
	if player.has_method("set_controls_enabled"):
		player.call("set_controls_enabled", false)
	_disable_player_interactor(true)
	# Пока едем, игрок невидим и не участвует в физике: его капсула не должна
	# толкать кузов и торчать из крыши.
	_set_player_active(false)

	_blend_to_car_camera()
	set_physics_process(true)


func detach(player: Node3D = null) -> void:
	if _car == null:
		return
	_driving = false
	_car.release_drive_input()
	set_physics_process(false)

	var who: Node3D = player if player != null else _player
	if who != null:
		who.visible = true
		if who.has_method("teleport_to"):
			who.call("teleport_to", _find_exit_position())
		_set_player_active(true)
		if who.has_method("set_controls_enabled"):
			who.call("set_controls_enabled", true)
		_disable_player_interactor(false)
		_blend_to_player_camera(who)
	_player = null


func request_exit() -> void:
	if _car != null and _car.has_method("exit"):
		_car.call("exit")


func is_driving() -> bool:
	return _driving


# --- Ввод --------------------------------------------------------------------


func _ensure_input_actions() -> void:
	_add_action(ACTION_ACCEL, [KEY_W, KEY_UP])
	_add_action(ACTION_BRAKE, [KEY_S, KEY_DOWN])
	_add_action(ACTION_LEFT, [KEY_A, KEY_LEFT])
	_add_action(ACTION_RIGHT, [KEY_D, KEY_RIGHT])
	_add_action(ACTION_HANDBRAKE, [KEY_SPACE])
	_add_action(ACTION_BOOST, [KEY_SHIFT])


func _add_action(action: StringName, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for code in keys:
		var exists: bool = false
		for event in InputMap.action_get_events(action):
			if event is InputEventKey and (event as InputEventKey).physical_keycode == code:
				exists = true
				break
		if exists:
			continue
		var key := InputEventKey.new()
		key.physical_keycode = code
		InputMap.action_add_event(action, key)


# --- Игрок -------------------------------------------------------------------


func _capture_player_shapes() -> void:
	_player_shapes.clear()
	if _player == null:
		return
	for child in _player.get_children():
		if child is CollisionShape3D:
			_player_shapes.append(child as CollisionShape3D)


func _set_player_active(active: bool) -> void:
	if _player == null:
		return
	_player.visible = active
	if _player.has_method("set_physics_process"):
		_player.set_physics_process(active)
	for shape in _player_shapes:
		if is_instance_valid(shape):
			shape.disabled = not active


func _disable_player_interactor(disabled: bool) -> void:
	if _player == null or not _player.has_method("get_interactor"):
		return
	var interactor: Node = _player.call("get_interactor")
	if interactor != null and interactor.has_method("set_interaction_enabled"):
		interactor.call("set_interaction_enabled", not disabled)


## Ищем пятачок у двери: точка справа от машины, спроецированная на землю лучом.
func _find_exit_position() -> Vector3:
	if _car == null:
		return Vector3.ZERO
	var candidates: Array[Vector3] = [
		_car.global_transform * door_offset,
		_car.global_transform * Vector3(-door_offset.x, door_offset.y, door_offset.z),
		_car.global_transform * Vector3(0.0, 0.0, 2.6),
		_car.global_transform * Vector3(0.0, 0.0, -2.6),
	]
	var space: PhysicsDirectSpaceState3D = _car.get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	if _car is CollisionObject3D:
		exclude.append((_car as CollisionObject3D).get_rid())

	for point in candidates:
		var from: Vector3 = point + Vector3.UP * 1.6
		var to: Vector3 = point + Vector3.DOWN * 2.0
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.exclude = exclude
		query.collide_with_areas = false
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			continue
		var ground: Vector3 = (hit["position"] as Vector3) + Vector3.UP * 0.1
		# Проверяем, что над точкой есть место под капсулу игрока (1.8 м).
		var head_query := PhysicsRayQueryParameters3D.create(
			ground + Vector3.UP * 0.2, ground + Vector3.UP * 1.9
		)
		head_query.exclude = exclude
		head_query.collide_with_areas = false
		var blocked: Dictionary = space.intersect_ray(head_query)
		if blocked.is_empty():
			return ground
		# Над точкой козырёк или стена — пробуем следующую сторону.
	return _car.global_position + Vector3.UP * 0.2


# --- Камера ------------------------------------------------------------------


func _blend_to_car_camera() -> void:
	if _chase_camera == null:
		return
	var from_camera: Camera3D = null
	if _player != null and _player.has_method("get_camera"):
		from_camera = _player.call("get_camera") as Camera3D
	if from_camera != null:
		_chase_camera.global_transform = from_camera.global_transform
	var target: Transform3D = _car.global_transform * _chase_local
	_chase_camera.current = true
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(_chase_camera, "global_transform", target, camera_blend_time)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_callback(_snap_chase_local)


func _snap_chase_local() -> void:
	# После перелёта камера снова жёстко привязана к машине.
	if _chase_camera != null and is_instance_valid(_chase_camera):
		_chase_camera.transform = _chase_local


func _blend_to_player_camera(player: Node3D) -> void:
	if _chase_camera == null or player == null or not player.has_method("get_camera"):
		return
	var player_camera: Camera3D = player.call("get_camera") as Camera3D
	if player_camera == null:
		return
	# Локальный трансформ камеры задан сценой (SpringArm), его и восстанавливаем.
	var local_transform: Transform3D = player_camera.transform
	var target: Transform3D = player_camera.get_parent().global_transform * local_transform
	player_camera.current = true
	player_camera.global_transform = _chase_camera.global_transform
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(player_camera, "global_transform", target, camera_blend_time)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
