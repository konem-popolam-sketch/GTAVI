class_name Player
extends CharacterBody3D
## Игрок от третьего лица.
##
## WASD — ходьба, Shift — бег (камера чуть расширяет FOV, корпус наклоняется
## вперёд), Space — прыжок, мышь — обзор, колесо — зум.
## Движение относительно собственного поворота корпуса (yaw), наклон камеры
## живёт на SpringArm3D. Гравитация берётся из ProjectSettings
## (physics/3d/default_gravity = 18), с запасным значением 18.
##
## ПУБЛИЧНЫЙ API (для интегратора):
##   группы: "player"
##   сигналы: interaction_target_changed(target: Node) — цель под прицелом
##   методы:  get_camera(), get_interactor(), set_controls_enabled(bool),
##            set_mouse_captured(bool), teleport_to(Vector3),
##            get_save_position(), is_mouse_captured(),
##            get_camera_distance(), is_body_mesh_visible()
##   свойства: global_position (позиция для сохранения), walk_speed, run_speed.

signal interaction_target_changed(target: Node)
## Цель под прицелом изменилась (null — цели нет). Удобно для HUD-подсказки.

@export_group("Движение")
@export var walk_speed: float = 4.0
@export var run_speed: float = 8.5
@export var jump_velocity: float = 6.0
@export var ground_acceleration: float = 18.0
@export var air_acceleration: float = 5.0
@export var fallback_gravity: float = 18.0

@export_group("Бег — обратная связь")
## Прибавка к FOV камеры на полном разгоне (градусы): картинка «разгоняется».
@export var sprint_fov_bonus: float = 8.0
## Наклон корпуса вперёд при беге (градусы).
@export var sprint_body_lean_degrees: float = 6.0
## Скорость сглаживания FOV и наклона (1/с): разгон/остановка без рывков.
@export var sprint_blend_speed: float = 6.0

@export_group("Камера")
@export var mouse_sensitivity: float = 0.0028
@export_range(-89.0, 0.0, 1.0) var min_pitch_degrees: float = -60.0
@export_range(0.0, 89.0, 1.0) var max_pitch_degrees: float = 40.0
@export var zoom_min: float = 2.2
@export var zoom_max: float = 7.0
@export var zoom_step: float = 0.5
@export var capture_mouse_on_start: bool = true

@export_group("Камера — скрытие меша игрока")
## Ниже этой длины SpringArm3D (после столкновения) меш игрока плавно гаснет.
@export var camera_fade_hide_distance: float = 1.6
## Выше этой длины меш возвращается. Разрыв с hide — гистерезис, чтобы не мигало.
@export var camera_fade_show_distance: float = 1.95
## Скорость затухания/возврата альфы (единиц в секунду).
@export var camera_fade_speed: float = 4.0

@export_group("Камера — пол и стены")
## Минимальная длина SpringArm3D: у стены камера прижимается к плечу, но не ближе.
@export var min_camera_distance: float = 1.2
## Минимальная высота камеры над полом под игроком (м).
@export var camera_floor_clearance: float = 0.35
## Скорость сглаживания длины SpringArm и наклона камеры (lerp ~= 10/с).
@export var camera_adjust_speed: float = 10.0

var gravity: float = 18.0
var controls_enabled: bool = true

var _pitch: float = 0.0
var _yaw: float = 0.0
var _desired_zoom: float = 4.2
var _camera_distance: float = 4.2
var _applied_pitch: float = 0.0
var _camera_close: bool = false
var _body_alpha: float = 1.0
var _body_fade_material: StandardMaterial3D = null
var _body_fade_supported: bool = false
var _body_base_emission: float = 0.0
var _body_base_rim: float = 0.0
## 0 — идём/стоим, 1 — бежим на полной скорости (сглаженный весовой коэффициент).
var _sprint_blend: float = 0.0
## FOV камеры до начала бега (−1 — бег не идёт, FOV не трогаем).
var _sprint_fov_base: float = -1.0
var _body_base_rotation: Vector3 = Vector3.ZERO

@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D
@onready var interactor: Interactor = $SpringArm3D/Camera3D/Interactor
@onready var body_mesh: MeshInstance3D = $Body


func _ready() -> void:
	add_to_group("player")
	var configured_gravity: Variant = ProjectSettings.get_setting(
		"physics/3d/default_gravity", fallback_gravity
	)
	if configured_gravity != null:
		gravity = float(configured_gravity)
	else:
		gravity = fallback_gravity
	_yaw = rotation.y
	_pitch = spring_arm.rotation.x
	_desired_zoom = clampf(spring_arm.spring_length, zoom_min, zoom_max)
	_camera_distance = _desired_zoom
	_applied_pitch = _pitch
	# Столкновения SpringArm считаем сами (_update_camera): встроенный расчёт
	# не умеет держать минимальную длину и высоту камеры над полом.
	spring_arm.collision_mask = 0
	# SpringArm3D не должен цепляться за собственное тело игрока.
	spring_arm.add_excluded_object(get_rid())
	interactor.target_changed.connect(_on_interactor_target_changed)
	camera_fade_show_distance = maxf(camera_fade_show_distance, camera_fade_hide_distance + 0.05)
	_prepare_body_fade()
	if body_mesh != null:
		_body_base_rotation = body_mesh.rotation
	# Захват курсора только в оконном режиме — headless-прогон не трогаем.
	if capture_mouse_on_start and DisplayServer.get_name() != "headless":
		set_mouse_captured(true)


func _process(delta: float) -> void:
	_update_camera(delta)
	_update_body_fade(delta)
	_update_sprint_feedback(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		set_mouse_captured(false)
		return

	if event is InputEventMouseMotion:
		if controls_enabled and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			var motion := event as InputEventMouseMotion
			_yaw = wrapf(_yaw - motion.relative.x * mouse_sensitivity, -PI, PI)
			rotation.y = _yaw
			var pitch := _pitch - motion.relative.y * mouse_sensitivity
			_pitch = clampf(
				pitch, deg_to_rad(min_pitch_degrees), deg_to_rad(max_pitch_degrees)
			)
			# spring_arm.rotation.x применяется в _update_camera с поправкой на пол.
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if not button.pressed:
			return
		match button.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_zoom(-zoom_step)
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom(zoom_step)
			MOUSE_BUTTON_LEFT:
				if (
					controls_enabled
					and not get_tree().paused
					and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
				):
					set_mouse_captured(true)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	if controls_enabled:
		if Input.is_action_just_pressed("jump") and is_on_floor():
			velocity.y = jump_velocity

		var input_dir: Vector2 = Input.get_vector(
			"move_left", "move_right", "move_forward", "move_back"
		)
		var direction: Vector3 = (
			(transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
		)
		var target_speed: float = run_speed if is_sprint_held() else walk_speed
		var accel: float = ground_acceleration if is_on_floor() else air_acceleration
		if direction.length_squared() > 0.001:
			velocity.x = move_toward(velocity.x, direction.x * target_speed, accel * delta)
			velocity.z = move_toward(velocity.z, direction.z * target_speed, accel * delta)
		else:
			velocity.x = move_toward(velocity.x, 0.0, accel * delta)
			velocity.z = move_toward(velocity.z, 0.0, accel * delta)
	else:
		var brake: float = ground_acceleration * delta
		velocity.x = move_toward(velocity.x, 0.0, brake)
		velocity.z = move_toward(velocity.z, 0.0, brake)

	move_and_slide()


# --- Публичный API -----------------------------------------------------------

## Зажат ли Shift. Действие "run" могло не срабатывать, если событие клавиши
## приходит без флага shift_pressed (зависит от платформы): действие сравнивает
## модификаторы, поэтому дополнительно смотрим физическое состояние клавиши.
func is_sprint_held() -> bool:
	return Input.is_action_pressed("run") or Input.is_physical_key_pressed(KEY_SHIFT)


func get_camera() -> Camera3D:
	return camera


func get_interactor() -> Interactor:
	return interactor


func set_controls_enabled(value: bool) -> void:
	controls_enabled = value
	if not value:
		velocity.x = 0.0
		velocity.z = 0.0


func set_mouse_captured(value: bool) -> void:
	if value:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func is_mouse_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func teleport_to(target_position: Vector3) -> void:
	global_position = target_position
	velocity = Vector3.ZERO


func get_save_position() -> Vector3:
	return global_position


## Текущая длина SpringArm3D после обработки столкновений (м).
func get_camera_distance() -> float:
	if spring_arm == null:
		return 0.0
	return spring_arm.get_hit_length()


## Видим ли меш игрока сейчас (используется для тестов/отладки).
func is_body_mesh_visible() -> bool:
	return body_mesh != null and body_mesh.visible


# --- Внутреннее --------------------------------------------------------------

## Камера: наклон ограничен полом, длина — стенами; без дёрганья (lerp).
func _update_camera(delta: float) -> void:
	if spring_arm == null or camera == null:
		return
	var dt := maxf(delta, 0.0001)
	var smooth := 1.0 - exp(-maxf(camera_adjust_speed, 0.01) * dt)
	var pivot := spring_arm.global_position
	var floor_y := global_position.y + camera_floor_clearance

	# 1) Наклон. При положительном pitch камера опускается под пол — ограничиваем.
	var floor_pitch_max := _max_floor_safe_pitch(pivot.y, floor_y, _camera_distance)
	var target_pitch := minf(_pitch, floor_pitch_max)
	_applied_pitch = lerpf(_applied_pitch, target_pitch, smooth)
	spring_arm.rotation.x = _applied_pitch

	# 2) Длина. Стена за плечом приближает камеру, но не ближе min_camera_distance.
	#    SpringArm3D выносит камеру вдоль +Z своей локальной оси.
	var direction := spring_arm.global_transform.basis.z
	if direction.length_squared() < 0.0001:
		return
	direction = direction.normalized()
	var desired := clampf(_desired_zoom, zoom_min, zoom_max)
	var safe_distance := desired
	var query := PhysicsRayQueryParameters3D.create(
		pivot, pivot + direction * desired, 1
	)
	query.exclude.append(get_rid())
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var hit_position: Vector3 = hit["position"]
		safe_distance = clampf(
			pivot.distance_to(hit_position) - spring_arm.margin,
			min_camera_distance,
			desired
		)
	_camera_distance = lerpf(_camera_distance, safe_distance, smooth)
	_camera_distance = clampf(_camera_distance, min_camera_distance, desired)
	spring_arm.spring_length = _camera_distance

	# 3) Страховка на переходном кадре: даже если сглаживание ещё не догнало,
	#    камера не опускается ниже пола.
	var camera_y := pivot.y - sin(_applied_pitch) * _camera_distance
	if camera_y < floor_y:
		_applied_pitch = minf(
			_applied_pitch,
			_max_floor_safe_pitch(pivot.y, floor_y, _camera_distance)
		)
		spring_arm.rotation.x = _applied_pitch


## Максимальный pitch (рад), при котором камера на длине arm_length остаётся
## не ниже floor_y: camera_y = pivot_y - arm_length * sin(pitch).
func _max_floor_safe_pitch(pivot_y: float, floor_y: float, arm_length: float) -> float:
	var sin_limit := clampf((pivot_y - floor_y) / maxf(arm_length, 0.01), -1.0, 1.0)
	return asin(sin_limit)


## Готовим отдельный экземпляр материала, чтобы менять альфу только у этого игрока.
func _prepare_body_fade() -> void:
	if body_mesh == null or body_mesh.mesh == null:
		return
	if body_mesh.mesh.get_surface_count() <= 0:
		return
	var current: Material = null
	if body_mesh.get_surface_override_material_count() > 0:
		current = body_mesh.get_surface_override_material(0)
	if current == null:
		current = body_mesh.mesh.surface_get_material(0)
	if current is StandardMaterial3D:
		_body_fade_material = (current as StandardMaterial3D).duplicate()
		_body_fade_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# Emission/rim не должны светиться сквозь затухающий меш — запоминаем
		# базовые значения и гасим их пропорционально альфе в _apply_body_alpha().
		_body_base_emission = _body_fade_material.emission_energy_multiplier
		_body_base_rim = _body_fade_material.rim
		body_mesh.set_surface_override_material(0, _body_fade_material)
		_body_fade_supported = true
	else:
		_body_fade_supported = false
	_body_alpha = 1.0
	body_mesh.visible = true


## Плавно скрывает меш, когда камера прижата к игроку в узком месте.
## Гистерезис: скрытие ниже camera_fade_hide_distance, возврат выше
## camera_fade_show_distance.
func _update_body_fade(delta: float) -> void:
	if body_mesh == null or spring_arm == null:
		return
	var distance := spring_arm.get_hit_length()
	# До первого физического кадра длина ещё не посчитана — не гасим меш зря.
	if distance <= 0.0:
		return
	if not _camera_close and distance < camera_fade_hide_distance:
		_camera_close = true
	elif _camera_close and distance > camera_fade_show_distance:
		_camera_close = false
	var target_alpha := 0.0 if _camera_close else 1.0
	if is_equal_approx(_body_alpha, target_alpha):
		return
	_body_alpha = move_toward(_body_alpha, target_alpha, maxf(camera_fade_speed, 0.01) * delta)
	_apply_body_alpha()


func _apply_body_alpha() -> void:
	if _body_fade_supported and _body_fade_material != null:
		var color := _body_fade_material.albedo_color
		color.a = _body_alpha
		_body_fade_material.albedo_color = color
		_body_fade_material.emission_energy_multiplier = _body_base_emission * _body_alpha
		_body_fade_material.rim = _body_base_rim * _body_alpha
	body_mesh.visible = _body_alpha > 0.01
	body_mesh.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if _body_alpha > 0.25
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)


## Бег «читается» и без цифр: камера плавно расширяет FOV, корпус наклоняется
## вперёд. Вес 0…1 сглаживается, поэтому нет рывка на старте и на остановке.
## FOV пишем только пока идёт бег — внешние правки camera.fov (скриншот-хуки
## MCP выставляют его напрямую) не затираются в покое.
func _update_sprint_feedback(delta: float) -> void:
	if camera == null or body_mesh == null:
		return
	var sprinting: bool = (
		controls_enabled
		and is_sprint_held()
		and is_on_floor()
		and Vector2(velocity.x, velocity.z).length() > walk_speed * 1.05
	)
	var smooth := 1.0 - exp(-maxf(sprint_blend_speed, 0.01) * maxf(delta, 0.0001))
	_sprint_blend = lerpf(_sprint_blend, 1.0 if sprinting else 0.0, smooth)
	if _sprint_blend < 0.001:
		_sprint_blend = 0.0
	if _sprint_blend > 0.0 and _sprint_fov_base < 0.0:
		_sprint_fov_base = camera.fov
	if _sprint_fov_base >= 0.0:
		camera.fov = _sprint_fov_base + sprint_fov_bonus * _sprint_blend
		if _sprint_blend <= 0.0:
			camera.fov = _sprint_fov_base
			_sprint_fov_base = -1.0
	body_mesh.rotation.x = (
		_body_base_rotation.x
		- deg_to_rad(sprint_body_lean_degrees) * _sprint_blend
	)


func _zoom(amount: float) -> void:
	if not controls_enabled:
		return
	_desired_zoom = clampf(_desired_zoom + amount, zoom_min, zoom_max)


func _on_interactor_target_changed(target: Node) -> void:
	interaction_target_changed.emit(target)
