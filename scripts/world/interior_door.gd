extends StaticBody3D
## Интерактивная дверь между улицей и интерьером (клуб / «Луна»).
##
## Одна и та же дверь работает в обе стороны:
##   * уличная (is_exit_door = false) находит точку входа по группе
##     (interior_group) и телепортирует туда игрока, запомнив точку возврата;
##   * внутренняя (is_exit_door = true) возвращает игрока туда, откуда пришли:
##     сначала meta "interior_return" на игроке, затем флаг QuestState (переживает
##     сохранение), затем fallback_exit_position.
##
## Совместимость с существующим Interactor: в _ready ставим meta interactable,
## display_name и interact_hint (HUD v2 читает interact_hint). Метод interact
## принимает игрока и сам ждёт кадр физики, чтобы SpringArm/камера пересчитали
## столкновения и не «проваливались» после телепорта.
##
## Интегратору: для связи достаточно, чтобы сцена интерьера была где-то
## инстанснута в дереве — уличная дверь найдёт её маркер по группе.

signal entered_interior(from_position: Vector3)
signal exited_interior(to_position: Vector3)

## Подпись для HUD-подсказки.
@export var door_name: String = "Дверь"
## Текст подсказки (meta "interact_hint"); HUD показывает его как есть.
@export var interact_hint: String = "E — войти"
## Группа маркера внутри интерьера, куда ведёт уличная дверь.
@export var interior_group: String = "interior_club"
## Внутренняя ли это дверь (возвращает наружу).
@export var is_exit_door: bool = false
## Ключ флага QuestState для позиции возврата (переживает save/load).
@export var save_key: String = "interior_return"
## Куда вернуть игрока, если нет ни meta, ни сохранённого флага.
@export var fallback_exit_position: Vector3 = Vector3.ZERO
## Поворот (yaw, радианы) при возврате: π — смотреть на юг (+Z).
@export var fallback_exit_yaw: float = 3.14159265

var _busy: bool = false


func _ready() -> void:
	add_to_group("interactable")
	add_to_group("interior_door")
	set_meta("interactable", true)
	set_meta("display_name", door_name)
	set_meta("interact_hint", interact_hint)


## Вызывается Interactor'ом игрока (E рядом с дверью).
func interact(player: Node3D) -> void:
	if _busy or player == null or not is_instance_valid(player):
		return
	_busy = true
	if is_exit_door:
		_leave_to_outside(player)
	else:
		_enter_interior(player)
	# Даём физике и SpringArm один кадр на пересчёт после телепорта.
	await get_tree().physics_frame
	_reset_camera(player)
	_busy = false


func _enter_interior(player: Node3D) -> void:
	var marker := get_tree().get_first_node_in_group(interior_group) as Node3D
	if marker == null:
		push_warning("[interior_door] нет маркера входа группы '%s' — сцена интерьера не подключена" % interior_group)
		return
	var return_transform := player.global_transform
	player.set_meta("interior_return", return_transform)
	_persist_return(return_transform)
	_move_player(player, marker.global_position, marker.global_rotation.y)
	entered_interior.emit(return_transform.origin)


func _leave_to_outside(player: Node3D) -> void:
	var target := _read_return(player)
	_move_player(player, target.origin, target.basis.get_euler().y)
	player.remove_meta("interior_return")
	_clear_persisted()
	exited_interior.emit(target.origin)


func _read_return(player: Node3D) -> Transform3D:
	if player.has_meta("interior_return"):
		return player.get_meta("interior_return") as Transform3D
	var stored: Variant = _read_persisted()
	if stored != null:
		return stored as Transform3D
	var basis := Basis(Vector3.UP, fallback_exit_yaw)
	return Transform3D(basis, fallback_exit_position)


func _move_player(player: Node3D, target_position: Vector3, yaw: float) -> void:
	if player.has_method("teleport_to"):
		player.call("teleport_to", target_position)
	else:
		player.global_position = target_position
	player.rotation.y = yaw
	# Синхронизируем внутренний yaw игрока, иначе первый же поворот мыши дёрнет
	# камеру на старое направление (у Player приватный _yaw).
	if player.get("_yaw") != null:
		player.set("_yaw", yaw)
	player.force_update_transform()


## Сброс камеры на кадр: пересчитать трансформы, чтобы SpringArm не показывал
## старую позицию/дистанцию после телепорта.
func _reset_camera(player: Node3D) -> void:
	player.force_update_transform()
	if not player.has_method("get_camera"):
		return
	var camera := player.call("get_camera") as Camera3D
	if camera != null:
		camera.force_update_transform()


# --- Сохранение точки возврата (флаг QuestState переживает save/load) --------


func _quest_state() -> Node:
	return get_node_or_null("/root/QuestState")


func _persist_return(transform: Transform3D) -> void:
	var quest := _quest_state()
	if quest == null or not quest.has_method("set_flag"):
		return
	var yaw := transform.basis.get_euler().y
	quest.call("set_flag", save_key, [
		transform.origin.x, transform.origin.y, transform.origin.z, yaw
	])


func _read_persisted() -> Variant:
	var quest := _quest_state()
	if quest == null or not quest.has_method("get_flag"):
		return null
	var raw: Variant = quest.call("get_flag", save_key, null)
	if typeof(raw) != TYPE_ARRAY:
		return null
	var values: Array = raw
	if values.size() < 4:
		return null
	var origin := Vector3(float(values[0]), float(values[1]), float(values[2]))
	var basis := Basis(Vector3.UP, float(values[3]))
	return Transform3D(basis, origin)


func _clear_persisted() -> void:
	var quest := _quest_state()
	if quest == null or not quest.has_method("set_flag"):
		return
	quest.call("set_flag", save_key, null)
