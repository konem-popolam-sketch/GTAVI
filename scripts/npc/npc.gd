class_name NPC
extends StaticBody3D
## Неигровой персонаж: человек (scenes/actors/humanoid.tscn) с тёплой подсветкой,
## зоной детекта игрока и маркером доступного взаимодействия.
##
## ПУБЛИЧНЫЙ API (для интегратора):
##   группы: "npc", "interactable"
##   метаданные: "interactable" = true, "npc_id", "dialogue_id"
##   сигналы: interacted(npc, player)      — вызван interact()
##            player_entered_range(npc, player)
##            player_exited_range(npc, player)
##   методы:  interact(player), is_player_in_range(), set_display_name(text),
##            set_highlight(bool), set_skin(name), face_player(player),
##            set_walking(bool), is_walking(), set_walk_route(route, ...),
##            get_walker(), get_walk_velocity()
##   свойства: npc_id, display_name, dialogue_id, player_in_range, skin,
##             walk_enabled.
##
## skin — палитра одежды/волос из Humanoid.SKINS ("mila", "kostya", "foreman", ...).
## Живые NPC (walk_enabled/авто-маршрут): Костя и Тимур ходят сразу, Прораб —
## после флага night_started; Мила/Галя/автоответчик стоят на месте.
## Маршруты заданы относительными смещениями от позиции NPC (без правки сцен).

signal interacted(npc: NPC, player: Node3D)
signal player_entered_range(npc: NPC, player: Node3D)
signal player_exited_range(npc: NPC, player: Node3D)

@export var npc_id: String = "npc"
@export var display_name: String = "NPC"
@export var dialogue_id: String = ""
@export var detect_radius: float = 2.2
@export var highlight_enabled: bool = true
## Палитра внешности (см. Humanoid.SKINS).
@export var skin: String = "auto"
## Поворачиваться к подошедшему игроку.
@export var face_player_when_near: bool = true
## Скорость поворота к игроку, рад/с.
@export var turn_speed: float = 3.5
## Ходить по маршруту (компонент NPCWalker). По умолчанию false — NPC стоит.
@export var walk_enabled: bool = false

## Маршруты живых NPC — относительные смещения от их стартовой позиции.
const KOSTYA_POINTS := [
	Vector3(0.0, 0.0, 0.0), Vector3(1.4, 0.0, 0.8),
	Vector3(0.6, 0.0, 2.0), Vector3(-0.8, 0.0, 1.2),
]
const TIMUR_POINTS := [
	Vector3(0.0, 0.0, 0.0), Vector3(1.6, 0.0, -0.3),
]
const FOREMAN_POINTS := [
	Vector3(0.0, 0.0, 0.0), Vector3(1.2, 0.0, 0.4),
]

var player_in_range: bool = false
var _walker: NPCWalker = null
var _walk_velocity: Vector3 = Vector3.ZERO
var _custom_route: PackedVector3Array = PackedVector3Array()
var _custom_route_set: bool = false

var _base_light_energy: float = 1.1
var _last_player: Node3D = null
var _target_yaw: float = 0.0

@onready var body_mesh: MeshInstance3D = $Body
@onready var highlight: OmniLight3D = $Highlight
@onready var marker: MeshInstance3D = $Marker
@onready var name_label: Label3D = $NameLabel
@onready var detect_area: Area3D = $DetectArea


func _ready() -> void:
	add_to_group("npc")
	add_to_group("interactable")
	set_meta("interactable", true)
	set_meta("npc_id", npc_id)
	set_meta("dialogue_id", dialogue_id)
	_base_light_energy = highlight.light_energy
	name_label.text = display_name
	marker.visible = false
	_set_highlight(false)
	_apply_detect_radius()
	_resolve_skin()
	_apply_skin()
	_target_yaw = rotation.y
	detect_area.body_entered.connect(_on_body_entered)
	detect_area.body_exited.connect(_on_body_exited)
	set_process(true)
	_setup_walking()


func _process(delta: float) -> void:
	if marker.visible:
		var pulse: float = 1.0 + 0.12 * sin(Time.get_ticks_msec() / 1000.0 * 3.0)
		marker.scale = Vector3(pulse, pulse, pulse)
	# Ходящий NPC смотрит по маршруту; поворотом управляет NPCWalker.
	if face_player_when_near and player_in_range and not is_walking():
		update_facing(delta)


# --- Публичный API -----------------------------------------------------------

## Вызывается интерактором игрока. Всегда шлёт сигнал interacted —
## решение о старте диалога принимает подписчик (DialogueManager).
func interact(player: Node3D = null) -> void:
	if player == null:
		player = get_tree().get_first_node_in_group("player") as Node3D
	interacted.emit(self, player)


func is_player_in_range() -> bool:
	return player_in_range


func get_dialogue_id() -> String:
	return dialogue_id


func set_display_name(value: String) -> void:
	display_name = value
	name_label.text = value


func set_highlight(enabled: bool) -> void:
	highlight_enabled = enabled
	_set_highlight(player_in_range and enabled)


## Меняет палитру внешности на лету (см. Humanoid.SKINS).
func set_skin(value: String) -> void:
	skin = value
	_apply_skin()


## Повернуть NPC лицом к точке (например, к игроку).
func face_player(player: Node3D = null) -> void:
	var target: Node3D = player if player != null else _last_player
	if target == null:
		return
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.001:
		return
	_target_yaw = atan2(-to_target.x, -to_target.z)
	rotation.y = _target_yaw


## Включить/выключить ходьбу. Создаёт компонент NPCWalker при необходимости.
func set_walking(enabled: bool) -> void:
	walk_enabled = enabled
	if not enabled:
		if _walker != null:
			_walker.set_walking_enabled(false)
		return
	_ensure_walker()
	if _walker != null:
		_walker.set_walking_enabled(true)


## Идёт ли NPC по маршруту прямо сейчас (компонент включён).
func is_walking() -> bool:
	return walk_enabled and _walker != null and _walker.is_walking_enabled()


## Задать собственный маршрут (мировые точки) — для интегратора/QA.
func set_walk_route(
	route: PackedVector3Array,
	walk_speed: float = 1.3,
	pause_min: float = 2.0,
	pause_max: float = 6.0,
	look_radius: float = 0.0
) -> void:
	_custom_route = route.duplicate()
	_custom_route_set = true
	if _walker != null:
		_walker.configure(_custom_route, walk_speed, pause_min, pause_max, look_radius)


func get_walker() -> NPCWalker:
	return _walker


## Текущая горизонтальная скорость для Humanoid (анимация walk/idle).
func get_walk_velocity() -> Vector3:
	return _walk_velocity


func set_walk_velocity(value: Vector3) -> void:
	_walk_velocity = value


## Плавный доворот к игроку (вызывается из _process, пока он в радиусе).
func update_facing(delta: float) -> void:
	if _last_player == null:
		return
	var to_target: Vector3 = _last_player.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.001:
		return
	_target_yaw = atan2(-to_target.x, -to_target.z)
	rotation.y = lerp_angle(rotation.y, _target_yaw, clampf(turn_speed * delta, 0.0, 1.0))


# --- Живые NPC: маршруты и компонент ходьбы ----------------------------------

func _setup_walking() -> void:
	if npc_id == "foreman":
		var quest := get_node_or_null("/root/QuestState")
		if quest != null and quest.has_signal("flag_changed"):
			if not quest.flag_changed.is_connected(_on_quest_flag_changed):
				quest.flag_changed.connect(_on_quest_flag_changed)
	if not walk_enabled and not _should_auto_walk():
		return
	if not _custom_route_set and _default_points().is_empty():
		return
	set_walking(true)


func _should_auto_walk() -> bool:
	match npc_id:
		"kostya", "timur":
			return true
		"foreman":
			var quest := get_node_or_null("/root/QuestState")
			if quest == null or not quest.has_method("has_flag"):
				return false
			# night_started по сюжету скрывает прораба (quest_director), поэтому
			# видимый второй акт — mila_confessed (он у машины); флаг night_started
			# тоже учитываем, если NPC кто-то оставил видимым.
			return quest.has_flag("mila_confessed") or quest.has_flag("night_started")
	return false


func _ensure_walker() -> void:
	if _walker != null:
		return
	_walker = NPCWalker.new()
	_walker.name = "NPCWalker"
	add_child(_walker)
	var points: PackedVector3Array = _custom_route.duplicate() if _custom_route_set else _points_to_global(_default_points())
	_walker.configure(points, _default_speed(), _default_pause_min(), _default_pause_max(), _default_look_radius())


func _default_points() -> Array:
	match npc_id:
		"kostya":
			return KOSTYA_POINTS
		"timur":
			return TIMUR_POINTS
		"foreman":
			return FOREMAN_POINTS
	return []


func _points_to_global(points: Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for offset in points:
		result.append(global_position + (offset as Vector3))
	return result


func _default_speed() -> float:
	match npc_id:
		"kostya":
			return 1.1
		"timur":
			return 1.3
		"foreman":
			return 1.15
	return 1.3


func _default_pause_min() -> float:
	return 2.0 if npc_id == "kostya" else 4.0 if npc_id == "foreman" else 2.0


func _default_pause_max() -> float:
	return 2.8 if npc_id == "kostya" else 6.0 if npc_id == "foreman" else 4.0


func _default_look_radius() -> float:
	return 4.0 if npc_id == "timur" else 0.0


func _on_quest_flag_changed(flag: String, value: Variant) -> void:
	if npc_id != "foreman" or not bool(value):
		return
	if flag != "night_started" and flag != "mila_confessed":
		return
	if not is_walking():
		set_walking(true)


# --- Внутреннее --------------------------------------------------------------

func _set_highlight(enabled: bool) -> void:
	if highlight != null:
		highlight.light_energy = _base_light_energy * (1.0 if enabled else 0.7)
	if marker != null:
		marker.visible = enabled
		if not enabled:
			marker.scale = Vector3.ONE


## "auto" — палитра по npc_id (mila/kostya/foreman/...), иначе общий "npc".
func _resolve_skin() -> void:
	if skin == "" or skin == "auto":
		skin = npc_id if npc_id != "" else "npc"
		if body_mesh != null and body_mesh.has_method("get_skin_names"):
			if not (npc_id in body_mesh.call("get_skin_names")):
				skin = "npc"


func _apply_skin() -> void:
	if body_mesh != null and body_mesh.has_method("apply_skin"):
		body_mesh.call("apply_skin", skin)


func _apply_detect_radius() -> void:
	var shape_node: CollisionShape3D = detect_area.get_node_or_null("CollisionShape3D")
	if shape_node != null and shape_node.shape is SphereShape3D:
		var sphere: SphereShape3D = (shape_node.shape as SphereShape3D).duplicate()
		sphere.radius = detect_radius
		shape_node.shape = sphere


func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	player_in_range = true
	_last_player = body
	_set_highlight(highlight_enabled)
	player_entered_range.emit(self, body)


func _on_body_exited(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	player_in_range = false
	if _last_player == body:
		_last_player = null
	_set_highlight(false)
	player_exited_range.emit(self, body)
