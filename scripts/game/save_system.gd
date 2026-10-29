class_name SaveSystem
extends RefCounted
## Сохранение/загрузка прогресса в user://save.json (JSON через FileAccess).
##
## Формат:
## {
##   "version": 1,
##   "saved_at": 1760000000,
##   "player": {"position": [x, y, z], "rotation_y": 0.0},
##   "quest": {"objective": "...", "flags": {...}, "ending_id": 1, ...}
## }
##
## Использование интегратором:
##   в _ready основной сцены:  SaveSystem.load_game(player)
##   при выходе/паузе:         SaveSystem.save_game(player)
##   вручную:                  SaveSystem.autosave()
## Сохранение позиции также происходит автоматически при смене цели/флагов
## квеста (QuestState вызывает autosave()).
##
## В песочнице DSH запись в %APPDATA%\Godot может быть запрещена — для
## headless-проверки переопределяйте APPDATA на временную папку.
##
## Смена названия игры (application/config/name) меняет каталог user://:
## например «GTAVI» → «ГТА 6». Путь к сейву внутри user:// жёсткий
## (user://save.json), поэтому при первом запуске под новым именем
## migrate_legacy_save() копирует старый save.json из соседних папок прежних
## названий (LEGACY_PROJECT_DIRS) — прогресс игрока не теряется.

const SAVE_PATH := "user://save.json"
const SAVE_VERSION := 1
const PLAYER_GROUP := "player"
## Прежние имена проекта: их папки в app_userdata проверяем при миграции.
const LEGACY_PROJECT_DIRS := ["GTAVI", "НОЧНАЯ СМЕНА", "NIGHT SHIFT", "Night Shift"]

static var _migration_checked: bool = false


## Сохранить игру. player можно не передавать — найдётся по группе "player".
static func save_game(player: Node3D = null) -> bool:
	var data := _read_payload()
	data["version"] = SAVE_VERSION
	data["saved_at"] = int(Time.get_unix_time_from_system())
	var target := player if player != null else _find_player()
	if target != null and is_instance_valid(target):
		data["player"] = {
			"position": _vector_to_array(target.global_position),
			"rotation_y": target.rotation.y,
		}
	var quest := _find_quest()
	if quest != null and quest.has_method("to_dict"):
		var quest_data: Dictionary = quest.to_dict()
		# Оружие не держит своё состояние в QuestState постоянно: перед записью
		# собираем актуальные ammo/reserve из узлов группы "weapon". Формат сейва
		# не меняется — это те же item_states, что и у коробки.
		_merge_weapon_states(quest_data)
		data["quest"] = quest_data
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[save] не удалось открыть %s для записи (код %d)" % [
			SAVE_PATH, FileAccess.get_open_error()
		])
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


## Загрузить игру. Возвращает true, если удалось применить хотя бы часть данных.
static func load_game(player: Node3D = null) -> bool:
	var data := _read_payload()
	if data.is_empty():
		return false
	var applied := false
	var target := player if player != null else _find_player()
	var player_data: Variant = data.get("player", null)
	if typeof(player_data) == TYPE_DICTIONARY and target != null and is_instance_valid(target):
		var pdata: Dictionary = player_data
		var position := _array_to_vector(pdata.get("position", []))
		if target.has_method("teleport_to"):
			target.teleport_to(position)
		else:
			target.global_position = position
		target.rotation.y = float(pdata.get("rotation_y", 0.0))
		applied = true
	var quest := _find_quest()
	var quest_data: Variant = data.get("quest", null)
	if quest != null and quest.has_method("from_dict") and typeof(quest_data) == TYPE_DICTIONARY:
		quest.from_dict(quest_data)
		# Пистолет не сам читает сейв на старте (main загружает его позже ready):
		# после восстановления QuestState раздаём item_states узлам оружия.
		_apply_weapon_states(quest)
		applied = true
	return applied


## Сохранить текущее состояние (то же, что save_game() без игрока).
static func autosave() -> bool:
	return save_game()


static func has_save() -> bool:
	migrate_legacy_save()
	return FileAccess.file_exists(SAVE_PATH)


## Перенести сейв из папки прежнего имени игры (после переименования проекта).
## Срабатывает один раз за запуск и только если нового сейва ещё нет.
## Возвращает true, если файл был скопирован.
static func migrate_legacy_save() -> bool:
	if _migration_checked:
		return false
	_migration_checked = true
	if FileAccess.file_exists(SAVE_PATH):
		return false
	var user_dir := ProjectSettings.globalize_path("user://").replace("\\", "/").trim_suffix("/")
	var app_dir := user_dir.get_base_dir()
	if app_dir.is_empty() or app_dir == user_dir:
		return false
	for legacy_dir in LEGACY_PROJECT_DIRS:
		var legacy_path := "%s/%s/save.json" % [app_dir, str(legacy_dir)]
		if not FileAccess.file_exists(legacy_path):
			continue
		var bytes := FileAccess.get_file_as_bytes(legacy_path)
		if bytes.is_empty():
			continue
		var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
		if file == null:
			push_warning("[save] не удалось перенести сейв из %s (код %d)" % [
				legacy_path, FileAccess.get_open_error()
			])
			return false
		file.store_buffer(bytes)
		file.close()
		print("[save] сейв перенесён из %s в %s" % [legacy_path, SAVE_PATH])
		return true
	return false


static func delete_save() -> bool:
	if not has_save():
		return true
	var absolute_path := ProjectSettings.globalize_path(SAVE_PATH)
	var error := DirAccess.remove_absolute(absolute_path)
	if error != OK:
		push_warning("[save] не удалось удалить %s (код %d)" % [SAVE_PATH, error])
		return false
	return true


static func get_saved_position() -> Vector3:
	var data := _read_payload()
	var player_data: Variant = data.get("player", null)
	if typeof(player_data) != TYPE_DICTIONARY:
		return Vector3.ZERO
	return _array_to_vector((player_data as Dictionary).get("position", []))


static func get_saved_quest() -> Dictionary:
	var data := _read_payload()
	var quest_data: Variant = data.get("quest", null)
	if typeof(quest_data) != TYPE_DICTIONARY:
		return {}
	return (quest_data as Dictionary).duplicate(true)


static func get_save_path() -> String:
	return SAVE_PATH


# --- Внутреннее -------------------------------------------------------------


static func _read_payload() -> Dictionary:
	migrate_legacy_save()
	if not FileAccess.file_exists(SAVE_PATH):
		return {}
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_warning("[save] не удалось открыть %s для чтения" % SAVE_PATH)
		return {}
	var raw := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[save] файл %s повреждён — начинаем с чистого листа" % SAVE_PATH)
		return {}
	return parsed


static func _find_player() -> Node3D:
	var loop := Engine.get_main_loop()
	if loop is not SceneTree:
		return null
	var tree := loop as SceneTree
	var player := tree.get_first_node_in_group(PLAYER_GROUP)
	return player as Node3D


static func _find_quest() -> Node:
	var loop := Engine.get_main_loop()
	if loop is not SceneTree:
		return null
	var tree := loop as SceneTree
	if tree.root == null:
		return null
	return tree.root.get_node_or_null("QuestState")


static func _find_tree() -> SceneTree:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return loop as SceneTree
	return null


## Перед записью подмешать в копию quest-данных актуальные ammo/reserve оружия.
## Важно: НЕ вызываем QuestState.set_item_state() — он делает autosave и это
## рекурсивно перезапустило бы save_game().
static func _merge_weapon_states(quest_data: Dictionary) -> void:
	var tree := _find_tree()
	if tree == null:
		return
	var states: Dictionary = {}
	var saved_states: Variant = quest_data.get("item_states", {})
	if typeof(saved_states) == TYPE_DICTIONARY:
		states = (saved_states as Dictionary).duplicate(true)
	for node in tree.get_nodes_in_group("weapon"):
		if not is_instance_valid(node):
			continue
		if not node.has_method("get_item_id") or not node.has_method("get_item_state"):
			continue
		var item_id := str(node.call("get_item_id"))
		var weapon_state: Variant = node.call("get_item_state")
		if item_id.is_empty() or typeof(weapon_state) != TYPE_DICTIONARY:
			continue
		if (weapon_state as Dictionary).is_empty():
			continue
		states[item_id] = (weapon_state as Dictionary).duplicate(true)
	quest_data["item_states"] = states


## После загрузки QuestState раздать item_states узлам группы "weapon".
static func _apply_weapon_states(quest: Node) -> void:
	var tree := _find_tree()
	if tree == null or not quest.has_method("get_item_state"):
		return
	for node in tree.get_nodes_in_group("weapon"):
		if not is_instance_valid(node):
			continue
		if not node.has_method("get_item_id") or not node.has_method("apply_item_state"):
			continue
		var item_id := str(node.call("get_item_id"))
		if item_id.is_empty():
			continue
		var saved_state: Variant = quest.call("get_item_state", item_id)
		if typeof(saved_state) != TYPE_DICTIONARY:
			continue
		if (saved_state as Dictionary).is_empty():
			continue
		# apply_item_state сам валидирует и логирует мусор.
		node.call("apply_item_state", saved_state)


static func _vector_to_array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


static func _array_to_vector(value: Variant) -> Vector3:
	if typeof(value) != TYPE_ARRAY:
		return Vector3.ZERO
	var items: Array = value
	if items.size() < 3:
		return Vector3.ZERO
	return Vector3(float(items[0]), float(items[1]), float(items[2]))
