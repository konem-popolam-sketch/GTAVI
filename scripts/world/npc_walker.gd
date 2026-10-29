class_name NPCWalker
extends Node
## Компонент «живого» NPC: ходьба по маршруту, паузы, доворот и реакция на игрока.
##
## Живёт дочерним узлом NPC (создаётся из npc.gd при walk_enabled/авто-маршруте).
## Двигает корень NPC (StaticBody3D) по горизонтали; Area3D детекта и коллизия
## едут вместе с ним, поэтому интерактор продолжает находить NPC в пути.
##
## Публичный API:
##   configure(route, speed, pause_min, pause_max, look_radius)
##   set_walking_enabled(bool), is_walking_enabled() -> bool
##   is_waiting() -> bool, is_reacting_to_player() -> bool
##   get_velocity() -> Vector3, get_waypoints_reached() -> int
##   get_travelled_distance() -> float, get_pause_remaining() -> float
##   get_route() -> PackedVector3Array, get_current_target() -> Vector3
##   signal waypoint_reached(index: int), walking_state_changed(walking: bool)
##
## Маршрут — мировые точки (npc.gd переводит относительные смещения от своей
## позиции). Скорость 1.1–1.5 м/с, пауза в точке 2–6 с, доворот lerp 6–8.
## Пока с этим NPC идёт диалог — стоит и смотрит на игрока; если player_look_radius
## > 0 (Тимур), останавливается и смотрит на игрока в радиусе, затем идёт дальше.

signal waypoint_reached(index: int)
signal walking_state_changed(walking: bool)

const MIN_SPEED := 1.1
const MAX_SPEED := 1.5
const MIN_PAUSE := 2.0
const MAX_PAUSE := 6.0
const TURN_SPEED := 7.0
const ARRIVAL_RADIUS := 0.12

## Скорость, м/с (ограничена 1.1–1.5).
@export var speed: float = 1.3
## Пауза в точке маршрута, с.
@export var pause_min: float = 2.0
@export var pause_max: float = 6.0
## Радиус реакции на игрока (0 — не реагировать).
@export var player_look_radius: float = 0.0
## Кто двигает NPC: true — компонент активен.
@export var starts_enabled: bool = true

var _npc: NPC = null
var _humanoid: Humanoid = null
var _route: PackedVector3Array = PackedVector3Array()
var _index: int = 0
var _pause_left: float = 0.0
var _enabled: bool = false
var _velocity: Vector3 = Vector3.ZERO
var _waypoints_reached: int = 0
var _travelled_distance: float = 0.0
var _reacting_to_player: bool = false
var _walking_anim: bool = false
var _last_global_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	_bind_parent()
	set_physics_process(_enabled)


## Настроить маршрут и параметры. Вызывается из NPC после добавления компонента.
func configure(
	route: PackedVector3Array,
	walk_speed: float,
	pause_seconds_min: float,
	pause_seconds_max: float,
	look_radius: float = 0.0
) -> void:
	_route = route.duplicate()
	speed = clampf(walk_speed, MIN_SPEED, MAX_SPEED)
	pause_min = clampf(pause_seconds_min, MIN_PAUSE, MAX_PAUSE)
	pause_max = clampf(maxf(pause_seconds_max, pause_min), MIN_PAUSE, MAX_PAUSE)
	player_look_radius = maxf(look_radius, 0.0)
	_index = 0
	_pause_left = 0.0
	_waypoints_reached = 0
	_travelled_distance = 0.0
	_velocity = Vector3.ZERO
	_reacting_to_player = false
	set_walking_enabled(starts_enabled)
	_last_global_position = _npc.global_position if _npc != null else Vector3.ZERO


func set_walking_enabled(enabled: bool) -> void:
	_enabled = enabled
	set_physics_process(enabled)
	if not enabled:
		_velocity = Vector3.ZERO
		_push_velocity_to_npc()
		_play_idle()
	walking_state_changed.emit(enabled)


func is_walking_enabled() -> bool:
	return _enabled


func is_waiting() -> bool:
	return _enabled and _pause_left > 0.0


func is_reacting_to_player() -> bool:
	return _reacting_to_player


func get_velocity() -> Vector3:
	return _velocity


func get_waypoints_reached() -> int:
	return _waypoints_reached


func get_travelled_distance() -> float:
	return _travelled_distance


func get_pause_remaining() -> float:
	return _pause_left


func get_route() -> PackedVector3Array:
	return _route.duplicate()


func get_current_target() -> Vector3:
	if _route.is_empty():
		return _npc.global_position if _npc != null else Vector3.ZERO
	return _route[_index]


func _physics_process(delta: float) -> void:
	if not _enabled or _route.is_empty():
		return
	if _npc == null and not _bind_parent():
		return
	_reanchor_after_teleport()
	var player := _get_player()
	if _is_dialogue_with_me():
		_reacting_to_player = false
		_velocity = Vector3.ZERO
		_push_velocity_to_npc()
		_play_idle()
		if player != null:
			_turn_towards(player.global_position, delta)
		return
	if player_look_radius > 0.0 and player != null:
		if _flat_distance(player.global_position) <= player_look_radius:
			_reacting_to_player = true
			_velocity = Vector3.ZERO
			_push_velocity_to_npc()
			_play_idle()
			_turn_towards(player.global_position, delta)
			return
	_reacting_to_player = false
	if _pause_left > 0.0:
		_pause_left = maxf(0.0, _pause_left - delta)
		_velocity = Vector3.ZERO
		_push_velocity_to_npc()
		_play_idle()
		return
	var target := _route[_index]
	var to_target := target - _npc.global_position
	to_target.y = 0.0
	if to_target.length() <= ARRIVAL_RADIUS:
		_arrive_at_waypoint()
		return
	var direction := to_target.normalized()
	_turn_towards(_npc.global_position + direction, delta)
	var step := speed * delta
	_velocity = direction * speed
	_npc.global_position += direction * step
	_travelled_distance += step
	_push_velocity_to_npc()
	_play_walk()


## Если NPC телепортировали извне (QuestDirector переставил к машине/на сцену),
## сдвигаем маршрут на ту же дельту — иначе он пошёл бы обратно через всю карту.
func _reanchor_after_teleport() -> void:
	if _last_global_position != Vector3.ZERO:
		var drift := _npc.global_position - _last_global_position
		drift.y = 0.0
		if drift.length() > 1.5:
			for i in _route.size():
				_route[i] += drift
	_last_global_position = _npc.global_position


func _arrive_at_waypoint() -> void:
	_waypoints_reached += 1
	var reached_index := _index
	_index = (_index + 1) % _route.size()
	_pause_left = randf_range(pause_min, pause_max)
	_velocity = Vector3.ZERO
	_push_velocity_to_npc()
	_play_idle()
	waypoint_reached.emit(reached_index)


func _bind_parent() -> bool:
	_npc = get_parent() as NPC
	if _npc == null:
		push_warning("[walker] родитель должен быть NPC")
		set_physics_process(false)
		return false
	_humanoid = _npc.get_node_or_null("Body") as Humanoid
	if _humanoid != null:
		# Скорость анимации под медленный шаг NPC, чтобы walk не «слайд-шоу».
		_humanoid.walk_speed = clampf(speed * 1.35, 1.8, 2.4)
		_humanoid.play_idle()
	return true


func _push_velocity_to_npc() -> void:
	if _npc != null:
		_npc.set_walk_velocity(_velocity)


func _play_walk() -> void:
	if _walking_anim or _humanoid == null:
		return
	_walking_anim = true
	_humanoid.play_walk()


func _play_idle() -> void:
	if not _walking_anim or _humanoid == null:
		return
	_walking_anim = false
	_humanoid.play_idle()


func _turn_towards(target: Vector3, delta: float) -> void:
	var to_target := target - _npc.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return
	var yaw := atan2(-to_target.x, -to_target.z)
	_npc.rotation.y = lerp_angle(_npc.rotation.y, yaw, clampf(TURN_SPEED * delta, 0.0, 1.0))


func _flat_distance(target: Vector3) -> float:
	var delta := target - _npc.global_position
	delta.y = 0.0
	return delta.length()


func _get_player() -> Node3D:
	var loop := Engine.get_main_loop()
	if loop is not SceneTree:
		return null
	return (loop as SceneTree).get_first_node_in_group("player") as Node3D


func _is_dialogue_with_me() -> bool:
	var manager := get_node_or_null("/root/DialogueManager")
	if manager == null or not manager.has_method("is_active"):
		return false
	if not manager.is_active():
		return false
	if not manager.has_method("get_npc"):
		return true
	return manager.get_npc() == _npc
