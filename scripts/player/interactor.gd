class_name Interactor
extends RayCast3D
## Интерактивный луч из камеры игрока.
##
## Ищет узлы с метаданными interactable (meta "interactable" = true) или с
## методом interact(); по нажатию E вызывает interact() у цели.
## Луч стартует из камеры и автоматически удлиняется так, чтобы доставать
## примерно на interact_range от игрока (камера висит позади на spring arm).
##
## ПУБЛИЧНЫЙ API (для интегратора):
##   сигналы: target_changed(target: Node), interacted(target: Node)
##   методы:  get_current_target(), set_interaction_enabled(bool)
##   свойства: interact_range, interaction_enabled, current_target
##   во время диалога вызови set_interaction_enabled(false), чтобы E
##   не перезапускал разговор.

signal target_changed(target: Node)
signal interacted(target: Node)

@export var interact_range: float = 3.0
@export var interaction_enabled: bool = true
@export var require_proximity: bool = true
## Если true, E срабатывает только при захваченном курсоре (диалог/пауза
## обычно отпускают курсор — так случайный E не перезапускает диалог).
@export var require_mouse_captured: bool = false

var current_target: Node = null
var player: Node3D = null


func _ready() -> void:
	enabled = true
	collide_with_areas = true
	collide_with_bodies = true
	player = get_tree().get_first_node_in_group("player") as Node3D
	if player == null:
		# Запасной путь: ближайший CharacterBody3D-предок (например, в песочнице).
		var node: Node = self
		while node != null:
			if node is CharacterBody3D:
				player = node as Node3D
				break
			node = node.get_parent()
	if player is CollisionObject3D:
		add_exception(player as CollisionObject3D)


func _physics_process(_delta: float) -> void:
	_update_ray_length()
	force_raycast_update()
	_update_target()

	if (
		interaction_enabled
		and current_target != null
		and not get_tree().paused
		and Input.is_action_just_pressed("interact")
		and _mouse_condition_ok()
	):
		_try_interact()


# --- Публичный API -----------------------------------------------------------

func get_current_target() -> Node:
	return current_target


func set_interaction_enabled(value: bool) -> void:
	interaction_enabled = value
	if not value and current_target != null:
		current_target = null
		target_changed.emit(null)


# --- Внутреннее --------------------------------------------------------------

func _mouse_condition_ok() -> bool:
	if not require_mouse_captured:
		return true
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _update_ray_length() -> void:
	var length: float = interact_range + 1.0
	if player != null:
		length = maxf(global_position.distance_to(player.global_position) + interact_range, 0.5)
	target_position = Vector3(0.0, 0.0, -length)


func _update_target() -> void:
	var found: Node = null
	if is_colliding():
		var collider: Object = get_collider()
		if collider is Node:
			found = _find_interactable(collider as Node)
		if found != null and require_proximity and player != null:
			var hit_offset: Vector3 = get_collision_point() - (player.global_position + Vector3.UP)
			if hit_offset.length() > interact_range + 1.0:
				found = null

	if found != current_target:
		current_target = found
		target_changed.emit(current_target)


func _find_interactable(start: Node) -> Node:
	var node: Node = start
	while node != null:
		if node.has_meta("interactable") and bool(node.get_meta("interactable")):
			return node
		if node.has_method("interact"):
			return node
		node = node.get_parent()
	return null


func _try_interact() -> void:
	var target: Node = current_target
	if target == null or not target.has_method("interact"):
		return
	var args: Array = []
	for info: Dictionary in target.get_method_list():
		if String(info.get("name", "")) == "interact":
			var method_args: Array = info.get("args", [])
			if method_args.size() >= 1:
				args = [player]
			break
	target.callv("interact", args)
	interacted.emit(target)
