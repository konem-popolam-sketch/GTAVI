class_name DialogueData
extends RefCounted
## Загрузчик контента диалогов из res://scripts/dialogue/data/*.json.
##
## Схема одного диалога (корневой ключ — id диалога):
## {
##   "mila": {
##     "title": "Мила у входа в «Луну»",
##     "speaker": "Мила",                     # спикер по умолчанию
##     "start": "mila_01",
##     "nodes": {
##       "mila_01": {
##         "speaker": "Мила",                 # опционально, переопределяет спикера
##         "text": "…",
##         "next": "mila_02",                 # null или "" = конец диалога
##         "choices": [                       # 1–3 варианта ответа
##           {"text": "Отдать коробку", "next": "end_deliver"}
##         ],
##         "effect": {                        # применяется при входе в узел
##           "objective": "Проверь автоответчик",
##           "set_flag": "package_delivered",
##           "flags": {"ключ": true}
##         },
##         "ending": 1,                       # номер концовки
##         "ending_title": "Молчание"
##       }
##     }
##   }
## }
##
## Статический кэш: файлы читаются один раз, повторно — только с force_reload.

const DATA_DIR := "res://scripts/dialogue/data"
const DATA_FILES: PackedStringArray = [
	"night_shift_dialogues.json",
	"finale_dialogues.json",
	"weapon_branch.json",
]
const MAX_CHOICES := 3

static var _cache: Dictionary = {}
static var _errors: PackedStringArray = []
static var _loaded: bool = false


## Читает все файлы контента и возвращает {dialogue_id: dialogue_dict}.
static func load_all(force_reload: bool = false) -> Dictionary:
	if _loaded and not force_reload:
		return _cache
	_cache.clear()
	_errors.clear()
	for file_name in DATA_FILES:
		var path := "%s/%s" % [DATA_DIR, file_name]
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			_errors.append("Не открывается файл диалогов: %s" % path)
			continue
		var raw := file.get_as_text()
		file.close()
		var json := JSON.new()
		var parse_error := json.parse(raw)
		if parse_error != OK:
			_errors.append("JSON %s, строка %d: %s" % [
				path, json.get_error_line(), json.get_error_message()
			])
			continue
		var parsed: Variant = json.data
		if typeof(parsed) != TYPE_DICTIONARY:
			_errors.append("Ожидался объект в корне JSON: %s" % path)
			continue
		var root: Dictionary = parsed
		for key in root.keys():
			var dialogue_id := str(key)
			if dialogue_id.begins_with("_"):
				continue
			var dialogue: Variant = root[key]
			if typeof(dialogue) != TYPE_DICTIONARY:
				_errors.append("Диалог '%s' — не объект" % dialogue_id)
				continue
			var issues := _validate_dialogue(dialogue_id, dialogue)
			if not issues.is_empty():
				_errors.append_array(issues)
				continue
			_cache[dialogue_id] = dialogue
	_loaded = true
	if not _errors.is_empty():
		for message in _errors:
			push_warning("[dialogue_data] %s" % message)
	print("[dialogue_data] диалогов загружено: %d — %s" % [
		_cache.size(), ", ".join(PackedStringArray(_cache.keys()))
	])
	return _cache


## Диалог по id; пустой Dictionary, если такого нет.
static func get_dialogue(dialogue_id: String) -> Dictionary:
	load_all()
	return _cache.get(dialogue_id, {})


static func has_dialogue(dialogue_id: String) -> bool:
	load_all()
	return _cache.has(dialogue_id)


static func get_dialogue_ids() -> PackedStringArray:
	load_all()
	var ids := PackedStringArray()
	for key in _cache.keys():
		ids.append(str(key))
	return ids


static func get_start_node(dialogue: Dictionary) -> String:
	return _as_string(dialogue.get("start", ""))


## null в JSON превращается в "<null>", а нам нужна пустая строка.
static func _as_string(value: Variant) -> String:
	if value == null:
		return ""
	return str(value)


static func get_node_data(dialogue: Dictionary, node_id: String) -> Dictionary:
	var nodes: Variant = dialogue.get("nodes", {})
	if typeof(nodes) != TYPE_DICTIONARY:
		return {}
	return (nodes as Dictionary).get(node_id, {})


## Все проблемы, найденные при последней загрузке (пусто = контент валиден).
static func get_errors() -> PackedStringArray:
	return _errors.duplicate()


## Количество узлов (для отчёта/тестов).
static func count_nodes(dialogue_id: String) -> int:
	var dialogue := get_dialogue(dialogue_id)
	var nodes: Variant = dialogue.get("nodes", {})
	if typeof(nodes) != TYPE_DICTIONARY:
		return 0
	return (nodes as Dictionary).size()


## Полная проверка схемы диалога. Возвращает список ошибок.
static func _validate_dialogue(dialogue_id: String, dialogue: Dictionary) -> PackedStringArray:
	var issues := PackedStringArray()
	var nodes_variant: Variant = dialogue.get("nodes", null)
	if typeof(nodes_variant) != TYPE_DICTIONARY:
		issues.append("Диалог '%s' без объекта nodes" % dialogue_id)
		return issues
	var nodes: Dictionary = nodes_variant
	if nodes.is_empty():
		issues.append("Диалог '%s' без реплик" % dialogue_id)
		return issues
	for node_id in nodes.keys():
		var node_variant: Variant = nodes[node_id]
		if typeof(node_variant) != TYPE_DICTIONARY:
			issues.append("Диалог '%s': узел '%s' — не объект" % [dialogue_id, node_id])
			continue
		var node: Dictionary = node_variant
		if str(node.get("text", "")).strip_edges().is_empty():
			issues.append("Диалог '%s': узел '%s' без текста" % [dialogue_id, node_id])
		var next_id := _as_string(node.get("next", ""))
		if not next_id.is_empty() and not nodes.has(next_id):
			issues.append("Диалог '%s': узел '%s' ссылается на несуществующий next '%s'" % [
				dialogue_id, node_id, next_id
			])
		var choices: Variant = node.get("choices", [])
		if typeof(choices) != TYPE_ARRAY:
			issues.append("Диалог '%s': choices узла '%s' — не массив" % [dialogue_id, node_id])
			continue
		var choice_list: Array = choices
		if choice_list.size() > MAX_CHOICES:
			issues.append("Диалог '%s': у узла '%s' больше %d вариантов" % [
				dialogue_id, node_id, MAX_CHOICES
			])
		for choice_index in choice_list.size():
			var choice_variant: Variant = choice_list[choice_index]
			if typeof(choice_variant) != TYPE_DICTIONARY:
				issues.append("Диалог '%s': вариант %d узла '%s' — не объект" % [
					dialogue_id, choice_index, node_id
				])
				continue
			var choice: Dictionary = choice_variant
			if str(choice.get("text", "")).strip_edges().is_empty():
				issues.append("Диалог '%s': вариант %d узла '%s' без текста" % [
					dialogue_id, choice_index, node_id
				])
			var choice_next := _as_string(choice.get("next", ""))
			if choice_next.is_empty() or not nodes.has(choice_next):
				issues.append("Диалог '%s': вариант %d узла '%s' ведёт в несуществующий узел '%s'" % [
					dialogue_id, choice_index, node_id, choice_next
				])
	var start_id := _as_string(dialogue.get("start", ""))
	if start_id.is_empty() or not nodes.has(start_id):
		issues.append("Диалог '%s': стартовый узел '%s' отсутствует" % [dialogue_id, start_id])
	return issues
