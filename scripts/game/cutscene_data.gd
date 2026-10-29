class_name CutsceneData
extends RefCounted
## CutsceneData — загрузка и валидация данных катсцен (JSON).
##
## Данные лежат в scripts/game/cutscenes/*.json. Сценарист/Тору правит там
## только текст и тайминги, не трогая код: катсцена — это id, длительность,
## флаг просмотра и список шагов.
##
## Шаг (словарь):
##   t          — время начала, сек
##   type       — camera | player_move | line | title | fade | flash | flag |
##                objective | item_add | item_remove | sfx | npc | npc_move | end
##   camera:    pos [x,y,z], look_at [x,y,z], fov, to [x,y,z], look_at_to, duration
##   player_move: from, to, duration, face_movement (bool), yaw
##   line:      dialogue_id + node_id (текст берётся из JSON диалогов) или
##              inline speaker/text; duration
##   title:     text, duration
##   fade:      alpha (0..1), duration
##   flag:      flag, value
##   objective: text
##   item_add/item_remove: item, name (для add)
##   sfx:       name, position (optional)
##   npc:       npc_id, visible
##   npc_move:  npc_id, from, to, duration
##   end:       player_position, player_yaw, next_dialogue (optional)
##
## Публичный API:
##   static load_all(force_reload = false) -> Dictionary
##   static get_cutscene(id) -> Dictionary
##   static has_cutscene(id) -> bool
##   static get_ids() -> PackedStringArray
##   static get_errors() -> PackedStringArray
##   static get_steps(data) -> Array
##   static get_seen_flag(data) -> String
##   static get_duration(data) -> float
##   static resolve_line(step) -> Dictionary {speaker, text, dialogue_id, node_id}

const SCENE_DIR := "res://scripts/game/cutscenes"
const DATA_FILES := [
	"prologue.json",
	"box.json",
	"weapon.json",
	"weapon_alt.json",
]
const DIALOGUE_DATA := preload("res://scripts/dialogue/dialogue_data.gd")

static var _cache: Dictionary = {}
static var _errors: PackedStringArray = PackedStringArray()
static var _loaded: bool = false
static var _voice_cache: Dictionary = {}
static var _voice_loaded: bool = false


static func load_all(force_reload: bool = false) -> Dictionary:
	if _loaded and not force_reload:
		return _cache
	_cache.clear()
	_errors.clear()
	for file_name in DATA_FILES:
		var path := "%s/%s" % [SCENE_DIR, file_name]
		if not FileAccess.file_exists(path):
			_errors.append("нет файла катсцены: %s" % path)
			continue
		var raw := FileAccess.get_file_as_string(path)
		if raw.strip_edges().is_empty():
			_errors.append("пустой файл катсцены: %s" % path)
			continue
		var json := JSON.new()
		var parse_error := json.parse(raw)
		if parse_error != OK:
			_errors.append("%s: JSON, строка %d: %s" % [
				file_name, json.get_error_line(), json.get_error_message()
			])
			continue
		if typeof(json.data) != TYPE_DICTIONARY:
			_errors.append("%s: корень должен быть объектом" % file_name)
			continue
		var data: Dictionary = json.data
		var id := str(data.get("id", "")).strip_edges()
		if id.is_empty():
			_errors.append("%s: нет поля id" % file_name)
			continue
		if _cache.has(id):
			_errors.append("%s: повторный id «%s»" % [file_name, id])
			continue
		_errors.append_array(_validate(id, data))
		_cache[id] = data
	_loaded = true
	return _cache


static func get_cutscene(cutscene_id: String) -> Dictionary:
	load_all()
	var data: Variant = _cache.get(cutscene_id, {})
	if typeof(data) == TYPE_DICTIONARY:
		return data
	return {}


static func has_cutscene(cutscene_id: String) -> bool:
	return not get_cutscene(cutscene_id).is_empty()


static func get_ids() -> PackedStringArray:
	load_all()
	var ids := PackedStringArray()
	for key in _cache.keys():
		ids.append(str(key))
	ids.sort()
	return ids


static func get_errors() -> PackedStringArray:
	load_all()
	return _errors


static func get_steps(data: Dictionary) -> Array:
	var steps: Variant = data.get("steps", [])
	if typeof(steps) == TYPE_ARRAY:
		return steps
	return []


static func get_seen_flag(data: Dictionary) -> String:
	var explicit := str(data.get("seen_flag", "")).strip_edges()
	if not explicit.is_empty():
		return explicit
	var id := str(data.get("id", "")).strip_edges()
	if id.is_empty():
		return ""
	return "%s_seen" % id


static func get_duration(data: Dictionary) -> float:
	return maxf(float(data.get("duration", 0.0)), 0.001)


## Текст реплики: сначала inline из катсцены, иначе — из JSON диалогов.
static func resolve_line(step: Dictionary) -> Dictionary:
	var dialogue_id := str(step.get("dialogue_id", "")).strip_edges()
	var node_id := str(step.get("node_id", "")).strip_edges()
	var speaker := str(step.get("speaker", "")).strip_edges()
	var text := str(step.get("text", "")).strip_edges()
	if text.is_empty() and not dialogue_id.is_empty() and not node_id.is_empty():
		var dialogue := DIALOGUE_DATA.get_dialogue(dialogue_id)
		var node := DIALOGUE_DATA.get_node_data(dialogue, node_id)
		if node.is_empty():
			# Катсценные диалоги пока живут в voice_manifest.json (их ещё не
			# перенесли в общий DATA_FILES) — берём текст оттуда, чтобы у Эми
			# оставался один источник правды и id реплик для озвучки.
			node = _voice_node(dialogue_id, node_id)
		if not node.is_empty():
			text = str(node.get("text", "")).strip_edges()
			if speaker.is_empty():
				speaker = str(node.get("speaker", "")).strip_edges()
			if speaker.is_empty():
				speaker = str(dialogue.get("speaker", "")).strip_edges()
	return {
		"speaker": speaker,
		"text": text,
		"dialogue_id": dialogue_id,
		"node_id": node_id,
	}


static func _voice_node(dialogue_id: String, node_id: String) -> Dictionary:
	_load_voice_manifest()
	var dialogue: Variant = _voice_cache.get(dialogue_id, {})
	if typeof(dialogue) != TYPE_DICTIONARY:
		return {}
	var nodes: Variant = (dialogue as Dictionary).get("nodes", dialogue)
	if typeof(nodes) != TYPE_DICTIONARY:
		return {}
	var node: Variant = (nodes as Dictionary).get(node_id, {})
	if typeof(node) == TYPE_DICTIONARY:
		return node
	return {}


static func _load_voice_manifest() -> void:
	if _voice_loaded:
		return
	_voice_loaded = true
	var path := "res://scripts/dialogue/data/voice_manifest.json"
	if not FileAccess.file_exists(path):
		return
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return
	if typeof(json.data) == TYPE_DICTIONARY:
		_voice_cache = json.data


static func _validate(cutscene_id: String, data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var duration := float(data.get("duration", 0.0))
	if duration <= 0.0:
		errors.append("«%s»: duration должен быть > 0" % cutscene_id)
	var steps := get_steps(data)
	if steps.is_empty():
		errors.append("«%s»: нет steps" % cutscene_id)
	var previous_t := -1.0
	for index in steps.size():
		var step_variant: Variant = steps[index]
		if typeof(step_variant) != TYPE_DICTIONARY:
			errors.append("«%s»: шаг %d не объект" % [cutscene_id, index])
			continue
		var step: Dictionary = step_variant
		var step_t := float(step.get("t", -1.0))
		if step_t < 0.0:
			errors.append("«%s»: шаг %d без t" % [cutscene_id, index])
		if step_t < previous_t:
			errors.append("«%s»: шаг %d раньше предыдущего (t=%.2f)" % [
				cutscene_id, index, step_t
			])
		previous_t = maxf(previous_t, step_t)
		var type := str(step.get("type", "")).strip_edges()
		if type.is_empty():
			errors.append("«%s»: шаг %d без type" % [cutscene_id, index])
			continue
		if type == "line":
			var line := resolve_line(step)
			if str(line.get("text", "")).is_empty():
				errors.append("«%s»: шаг %d line без текста (dialogue_id/node_id?)" % [
					cutscene_id, index
				])
	return errors
