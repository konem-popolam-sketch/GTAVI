class_name CarriedItem
extends StaticBody3D
## CarriedItem — предмет, который курьер берёт с прилавка и несёт в руках.
##
## Сцена: scenes/objects/package.tscn (коробка «Посылки»).
## Игрок наводится на предмет и жмёт E (Interactor вызывает interact) — предмет
## подбирается, отключает коллизию, встаёт у груди игрока (справа, чуть впереди,
## чтобы не перекрывать камеру) и добавляется в инвентарь QuestState.
## Положить предмет можно в ItemDropZone (scene/objects/package_drop_zone.tscn):
## стойка прораба, ящик и т.п. — зона сама вызывает drop_at().
##
## Сохранение: предмет не теряется между запусками.
##   - в руках  -> QuestState.has_item(id) + item_states[id].state == "carried";
##   - на земле -> item_states[id] = {"state":"dropped","position":[x,y,z]};
##   - сдан     -> флаг <id>_delivered (например package_delivered) прячет предмет.
##
## Сигналы:
##   picked_up(item)            — предмет взят в руки
##   dropped(item, drop_target) — предмет положен (drop_target может быть null)
##
## Публичный API:
##   pick_up(player = null) -> bool
##   drop_at(world_position, drop_target = null) -> bool
##   is_carried() -> bool
##   get_item_id() -> String
##   get_item_data() -> Dictionary   # {"id": ..., "name": ...}
##   get_state_name() -> String      # "placed" | "carried" | "dropped" | "delivered"
##   set_usable(value)
##   get_player() -> Node3D

signal picked_up(item: CarriedItem)
signal dropped(item: CarriedItem, drop_target: Node)

enum ItemState { PLACED, CARRIED, DROPPED, DELIVERED }

const QUEST_PATH := "/root/QuestState"
const PLAYER_GROUP := "player"

@export var item_id: String = "package"
@export var item_name: String = "Посылка"
## Позиция у груди игрока в его локальных координатах (x — вправо, z — вперёд).
@export var chest_offset: Vector3 = Vector3(0.24, 1.18, -0.34)
## Поворот предмета в руках относительно игрока (градусы).
@export var carried_rotation_degrees: Vector3 = Vector3(-8.0, 0.0, 4.0)
## Можно ли подобрать предмет (например, до начала смены).
@export var usable: bool = true
## Восстанавливать состояние из QuestState при загрузке сцены/сейва.
@export var restore_from_save: bool = true
## Скорость доводки предмета к груди при переноске (1/с); 0 — жёсткая привязка.
@export var carry_smoothing: float = 0.0

var item_state: int = ItemState.PLACED

var _player: Node3D = null
var _home_position: Vector3 = Vector3.ZERO
var _home_rotation: Vector3 = Vector3.ZERO
var _saved_collision_layer: int = 1
var _saved_collision_mask: int = 1
var _quest: Node = null


func _ready() -> void:
	add_to_group("interactable")
	add_to_group("carried_items")
	set_meta("interactable", true)
	set_meta("item_id", item_id)
	set_meta("display_name", item_name)
	_saved_collision_layer = collision_layer
	_saved_collision_mask = collision_mask
	_home_position = global_position
	_home_rotation = rotation
	_quest = get_node_or_null(QUEST_PATH)
	if _quest != null and _quest.has_signal("flag_changed"):
		_quest.flag_changed.connect(_on_quest_flag_changed)
	# Восстановление после загрузки сейва — на следующем кадре, когда сцена собрана.
	if restore_from_save:
		call_deferred("_restore_from_save")


func _physics_process(delta: float) -> void:
	if item_state != ItemState.CARRIED:
		return
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group(PLAYER_GROUP) as Node3D
		if _player == null:
			return
	var base := _player.global_transform
	var target := base.origin + base.basis * chest_offset
	if carry_smoothing <= 0.0:
		global_position = target
	else:
		global_position = global_position.lerp(
			target, clampf(carry_smoothing * delta, 0.0, 1.0)
		)
	# Коробка поворачивается вместе с игроком и чуть наклонена, как в руках.
	var yaw := _player.rotation.y
	global_rotation = Vector3(
		deg_to_rad(carried_rotation_degrees.x),
		yaw + deg_to_rad(carried_rotation_degrees.y),
		deg_to_rad(carried_rotation_degrees.z)
	)


# --- Публичный API ----------------------------------------------------------


## Взять предмет в руки. Вызывается интерактором при нажатии E.
func pick_up(player: Node3D = null) -> bool:
	if item_state == ItemState.CARRIED or not usable:
		return false
	if _quest != null and _quest.has_flag("%s_delivered" % item_id):
		return false
	var target_player := player
	if target_player == null:
		target_player = get_tree().get_first_node_in_group(PLAYER_GROUP) as Node3D
	if target_player == null:
		push_warning("[carried_item] некуда взять '%s': игрок не найден" % item_id)
		return false
	_player = target_player
	item_state = ItemState.CARRIED
	top_level = true
	_collision_enabled(false)
	_add_to_inventory()
	if _quest != null and _quest.has_method("set_item_state"):
		_quest.set_item_state(item_id, {"state": "carried"})
	picked_up.emit(self)
	return true


## Положить предмет в мире. Позиция — мировая точка (например, стойка прораба).
func drop_at(world_position: Vector3, drop_target: Node = null) -> bool:
	if item_state != ItemState.CARRIED:
		return false
	global_position = world_position
	global_rotation = Vector3(0.0, _player.rotation.y if _player != null else 0.0, 0.0)
	item_state = ItemState.DROPPED
	top_level = true
	_collision_enabled(true)
	_remove_from_inventory()
	if _quest != null:
		if _quest.has_method("set_item_state"):
			_quest.set_item_state(item_id, {
				"state": "dropped",
				"position": [global_position.x, global_position.y, global_position.z],
			})
		if _quest.has_method("set_flag"):
			_quest.set_flag("%s_placed" % item_id, true)
	dropped.emit(self, drop_target)
	return true


func is_carried() -> bool:
	return item_state == ItemState.CARRIED


func get_item_id() -> String:
	return item_id


func get_item_data() -> Dictionary:
	return {"id": item_id, "name": item_name}


func get_player() -> Node3D:
	return _player


func get_state_name() -> String:
	match item_state:
		ItemState.CARRIED:
			return "carried"
		ItemState.DROPPED:
			return "dropped"
		ItemState.DELIVERED:
			return "delivered"
		_:
			return "placed"


func set_usable(value: bool) -> void:
	usable = value


## Прямоугольник коробки в мире (для маркеров/проверок).
func get_global_center() -> Vector3:
	return global_position


# --- Интерактор -------------------------------------------------------------


## Единая точка входа Interactor: E по предмету = взять.
func interact(player: Node3D = null) -> void:
	pick_up(player)


# --- Внутреннее -------------------------------------------------------------


func _add_to_inventory() -> void:
	if _quest == null or not _quest.has_method("add_item"):
		return
	var data := get_item_data()
	if not _quest.has_item(item_id):
		_quest.add_item(item_id, item_name)
	else:
		# Предмет уже в инвентаре (загрузка сейва) — флаг могли не выставить.
		if _quest.has_method("set_flag") and not _quest.has_flag("item_%s" % item_id):
			_quest.set_flag("item_%s" % item_id, true)


func _remove_from_inventory() -> void:
	if _quest != null and _quest.has_method("remove_item"):
		_quest.remove_item(item_id)


func _collision_enabled(enabled: bool) -> void:
	if enabled:
		collision_layer = _saved_collision_layer
		collision_mask = _saved_collision_mask
	else:
		collision_layer = 0
		collision_mask = 0


func _on_quest_flag_changed(flag: String, value: Variant) -> void:
	if not _is_truthy(value):
		return
	# Прораб забрал коробку прямо из рук (диалог поставил package_delivered).
	if flag == "%s_delivered" % item_id and item_state == ItemState.CARRIED:
		item_state = ItemState.DELIVERED
		_collision_enabled(false)
		_remove_from_inventory()
		visible = false
		if _quest != null and _quest.has_method("set_item_state"):
			_quest.set_item_state(item_id, {"state": "delivered"})


func _restore_from_save() -> void:
	if _quest == null:
		return
	if _quest.has_flag("%s_delivered" % item_id):
		item_state = ItemState.DELIVERED
		_collision_enabled(false)
		visible = false
		return
	if _quest.has_item(item_id):
		# Был в руках — вернуть в руки, не добавляя предмет в инвентарь повторно.
		item_state = ItemState.PLACED
		pick_up(get_tree().get_first_node_in_group(PLAYER_GROUP) as Node3D)
		return
	var saved: Dictionary = _quest.get_item_state(item_id)
	if saved.is_empty():
		return
	var saved_state := str(saved.get("state", ""))
	if saved_state == "carried":
		item_state = ItemState.PLACED
		pick_up(get_tree().get_first_node_in_group(PLAYER_GROUP) as Node3D)
	elif saved_state == "dropped":
		var position_data: Variant = saved.get("position", [])
		if typeof(position_data) == TYPE_ARRAY and (position_data as Array).size() >= 3:
			var items: Array = position_data
			global_position = Vector3(
				float(items[0]), float(items[1]), float(items[2])
			)
		top_level = true
		item_state = ItemState.DROPPED
		_collision_enabled(true)
	elif saved_state == "delivered":
		item_state = ItemState.DELIVERED
		_collision_enabled(false)
		visible = false
	else:
		# "placed": предмет на своём месте в сцене.
		global_position = _home_position
		rotation = _home_rotation


## Сохранённая домашняя позиция (для отладки/тестов).
func get_home_position() -> Vector3:
	return _home_position


## Флаги бывают не только булевы (site_code — строка), поэтому сырое значение
## нельзя сравнивать с true напрямую: в Godot 4 String != true — ошибка.
func _is_truthy(value: Variant) -> bool:
	match typeof(value):
		TYPE_BOOL:
			return value
		TYPE_INT:
			return int(value) != 0
		TYPE_FLOAT:
			return not is_zero_approx(float(value))
		TYPE_STRING, TYPE_STRING_NAME:
			return not str(value).is_empty()
		TYPE_NIL:
			return false
		_:
			return true
