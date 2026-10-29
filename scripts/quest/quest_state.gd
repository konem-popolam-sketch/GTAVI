extends Node
## QuestState — автолоад состояния квеста, сюжетных шагов, инвентаря и финала.
##
## Фаза 2 (t16, Ичиго): к целям/флагам/концовке добавлены
##   - стадии квеста (пошаговый квест-лог: id, заголовок, акт, тип шага);
##   - мини-инвентарь (id + имя предмета, синхронизирован с флагами item_*);
##   - состояние предметов в мире (item_states: где лежит/несётся предмет);
##   - сигналы для HUD: stage_changed(stage_id, title), inventory_changed(items).
##
## Старые методы и старый save.json полностью поддерживаются: в старом сейве
## нет stage_id/inventory/item_states — они выводятся из flags (например,
## package_delivered -> стадия «Проверь автоответчик», item_flashlight -> фонарь
## в инвентаре, completed + ending_id -> стадия «История завершена»).
##
## Публичный API (старое):
##   set_objective(text); get_objective() -> String
##   set_flag(name, value = true); has_flag(name) -> bool; get_flag(name, fallback)
##   get_flags() -> Dictionary
##   set_ending(id, title = ""); get_ending_id(); get_ending_title(); is_finished()
##   reset(); to_dict() / from_dict(data)
## Публичный API (t16):
##   get_stages() -> Array                 # [{id,title,act,kind,target,completed,active}]
##   get_current_stage_id() -> String
##   get_current_stage_title() -> String
##   get_current_stage() -> Dictionary
##   set_stage(id, update_objective = true) -> bool
##   advance_stage() -> bool
##   add_item(id, name = "") -> bool; remove_item(id) -> bool
##   has_item(id) -> bool; get_item(id) -> Dictionary; get_items() -> Array
##   get_item_state(id) -> Dictionary; set_item_state(id, state); clear_item_state(id)
## Сигналы:
##   objective_changed(text), flag_changed(flag, value), ending_reached(ending_id, title),
##   quest_completed(), state_changed(), stage_changed(stage_id, title),
##   inventory_changed(items)

signal objective_changed(text: String)
signal flag_changed(flag: String, value: Variant)
signal ending_reached(ending_id: int, title: String)
signal quest_completed()
signal state_changed()
signal stage_changed(stage_id: String, title: String)
signal inventory_changed(items: Array)

const DEFAULT_OBJECTIVE := "Отнеси посылку к пирсу"
const FINAL_OBJECTIVE := "История завершена"
const ENDING_TITLES := {
	1: "Молчание",
	2: "Голос",
	3: "Смена",
}
const DEFAULT_STAGE_ID := "deliver_package"
const FINISHED_STAGE_ID := "finished"

## Цепочка шагов квеста по библии §7.3. act — акт истории, kind — чем шаг
## закрывается: dialogue (разговор), item (предмет), point (точка на карте).
## target — подсказка интегратору/маркеру, к какому узлу ведёт шаг.
const STAGES := [
	{
		"id": "deliver_package",
		"title": "Отнеси посылку к пирсу",
		"act": 1,
		"kind": "item",
		"target": "foreman",
	},
	{
		"id": "check_answerphone",
		"title": "Проверь автоответчик у входа",
		"act": 1,
		"kind": "dialogue",
		"target": "voice",
	},
	{
		"id": "reach_dispatcher",
		"title": "Поднимись в диспетчерскую над «Луной»",
		"act": 2,
		"kind": "point",
		"target": "galya",
	},
	{
		"id": "find_site_code",
		"title": "Найди код на стройку у сторожа",
		"act": 2,
		"kind": "dialogue",
		"target": "timur",
	},
	{
		"id": "inspect_twin_box",
		"title": "Осмотри вторую точку на стройке",
		"act": 2,
		"kind": "point",
		"target": "twin_box",
	},
	{
		"id": "return_to_mila",
		"title": "Вернись к «Луне»: Мила у витрины",
		"act": 3,
		"kind": "dialogue",
		"target": "mila",
	},
	{
		"id": "find_foreman",
		"title": "Найди прораба на парковке",
		"act": 3,
		"kind": "dialogue",
		"target": "foreman",
	},
	{
		"id": "talk_to_kostya",
		"title": "Поговори с Костей",
		"act": 3,
		"kind": "dialogue",
		"target": "kostya",
	},
	{
		"id": "final_choice",
		"title": "Реши, что делать с коробкой",
		"act": 3,
		"kind": "point",
		"target": "pier",
	},
	{
		"id": "finished",
		"title": "История завершена",
		"act": 3,
		"kind": "end",
		"target": "",
	},
]

## Флаги, которые двигают шаг вперёд. Порядок совпадает с STAGES:
## берётся самый поздний выполненный флаг, поэтому загрузка старого сейва
## восстанавливает акт по флагам, а не по номеру.
const STAGE_FLAGS := [
	{"flag": "package_delivered", "stage": "check_answerphone"},
	{"flag": "night_started", "stage": "reach_dispatcher"},
	{"flag": "shift_log_seen", "stage": "find_site_code"},
	{"flag": "site_code", "stage": "inspect_twin_box"},
	{"flag": "twin_box_found", "stage": "return_to_mila"},
	{"flag": "mila_confessed", "stage": "find_foreman"},
	{"flag": "foreman_cornered", "stage": "talk_to_kostya"},
	{"flag": "kostya_witness", "stage": "final_choice"},
]

## Человеческие имена известных предметов; для остальных берётся id.
const ITEM_NAMES := {
	"package": "Посылка",
	"flashlight": "Фонарь",
}

## Автосохранение при каждом изменении цели/флагов/стадии/инвентаря
## (позиция игрока подхватывается SaveSystem, если Player уже в группе "player").
var auto_save_enabled: bool = true

var current_objective: String = DEFAULT_OBJECTIVE
var flags: Dictionary = {}
var ending_id: int = 0
var ending_title: String = ""
var completed: bool = false

var stage_id: String = DEFAULT_STAGE_ID
var carried_items: Array[Dictionary] = []
var item_states: Dictionary = {}

var _loading: bool = false


func _ready() -> void:
	print("[quest] стартовая цель: %s" % current_objective)
	print("[quest] стадий квеста: %d, текущая: %s" % [STAGES.size(), stage_id])


# --- Публичный API: цель и флаги (совместимость с фазой 1) -------------------


func set_objective(text: String) -> void:
	var new_text := text.strip_edges()
	if new_text.is_empty() or new_text == current_objective:
		return
	current_objective = new_text
	objective_changed.emit(current_objective)
	state_changed.emit()
	_autosave()


func get_objective() -> String:
	return current_objective


func set_flag(flag: String, value: Variant = true) -> void:
	var key := flag.strip_edges()
	if key.is_empty():
		return
	if flags.has(key) and flags[key] == value:
		return
	flags[key] = value
	flag_changed.emit(key, value)
	_sync_stage_from_flags()
	state_changed.emit()
	_autosave()


func has_flag(flag: String) -> bool:
	# Флаги бывают не только булевы: site_code — строка («4-0-7»).
	# Сравнение String == true в Godot 4 — ошибка, поэтому проверяем тип.
	var value: Variant = flags.get(flag, false)
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


func get_flag(flag: String, fallback: Variant = null) -> Variant:
	return flags.get(flag, fallback)


func get_flags() -> Dictionary:
	return flags.duplicate(true)


# --- Публичный API: концовка ------------------------------------------------


func set_ending(id: int, title: String = "") -> void:
	if id <= 0 or completed:
		return
	ending_id = id
	ending_title = title.strip_edges()
	if ending_title.is_empty():
		ending_title = str(ENDING_TITLES.get(id, "Концовка %d" % id))
	completed = true
	_apply_stage(FINISHED_STAGE_ID, true, false)
	ending_reached.emit(ending_id, ending_title)
	quest_completed.emit()
	state_changed.emit()
	_autosave()


func get_ending_id() -> int:
	return ending_id


func get_ending_title() -> String:
	return ending_title


func is_finished() -> bool:
	return completed


func reset() -> void:
	current_objective = DEFAULT_OBJECTIVE
	flags.clear()
	ending_id = 0
	ending_title = ""
	completed = false
	stage_id = DEFAULT_STAGE_ID
	carried_items.clear()
	item_states.clear()
	objective_changed.emit(current_objective)
	stage_changed.emit(stage_id, get_current_stage_title())
	inventory_changed.emit(get_items())
	state_changed.emit()


# --- Публичный API: шаги квеста (t16) ----------------------------------------


## Полный список стадий с признаком выполнения. Копия — менять снаружи безопасно.
func get_stages() -> Array:
	var result: Array = []
	var current := _stage_index(stage_id)
	for index in STAGES.size():
		var stage: Dictionary = (STAGES[index] as Dictionary).duplicate(true)
		stage["completed"] = index < current
		stage["active"] = index == current
		result.append(stage)
	return result


func get_current_stage_id() -> String:
	return stage_id


func get_current_stage_title() -> String:
	var index := _stage_index(stage_id)
	if index < 0:
		return current_objective
	return str((STAGES[index] as Dictionary).get("title", current_objective))


## Текущий шаг целиком: {id, title, act, kind, target, completed, active}.
func get_current_stage() -> Dictionary:
	var index := _stage_index(stage_id)
	if index < 0:
		return {
			"id": stage_id,
			"title": current_objective,
			"act": 0,
			"kind": "",
			"target": "",
			"completed": completed,
			"active": true,
		}
	var stage: Dictionary = (STAGES[index] as Dictionary).duplicate(true)
	stage["completed"] = false
	stage["active"] = true
	return stage


## Явный переход на стадию (например, из отладочного моста или триггера сцены).
## Обновляет цель по умолчанию (можно отключить third-аргументом).
func set_stage(new_stage_id: String, update_objective: bool = true) -> bool:
	if _stage_index(new_stage_id) < 0:
		push_warning("[quest] неизвестная стадия '%s'" % new_stage_id)
		return false
	if new_stage_id == stage_id:
		return false
	_apply_stage(new_stage_id, update_objective, true)
	return true


## Перейти к следующей стадии цепочки. false — если уже финал.
func advance_stage() -> bool:
	var next_index := _stage_index(stage_id) + 1
	if next_index < 0 or next_index >= STAGES.size():
		return false
	var next_id := str((STAGES[next_index] as Dictionary).get("id", ""))
	return set_stage(next_id, true)


# --- Публичный API: инвентарь (t16) -----------------------------------------


func add_item(item_id: String, item_name: String = "") -> bool:
	var key := item_id.strip_edges()
	if key.is_empty() or has_item(key):
		return false
	var display_name := item_name.strip_edges()
	if display_name.is_empty():
		display_name = str(ITEM_NAMES.get(key, key))
	carried_items.append({"id": key, "name": display_name})
	_set_item_flag(key, true)
	inventory_changed.emit(get_items())
	state_changed.emit()
	_autosave()
	return true


func remove_item(item_id: String) -> bool:
	var key := item_id.strip_edges()
	if not has_item(key):
		return false
	for index in range(carried_items.size() - 1, -1, -1):
		if str(carried_items[index].get("id", "")) == key:
			carried_items.remove_at(index)
	_set_item_flag(key, false)
	inventory_changed.emit(get_items())
	state_changed.emit()
	_autosave()
	return true


func has_item(item_id: String) -> bool:
	var key := item_id.strip_edges()
	for entry in carried_items:
		if str(entry.get("id", "")) == key:
			return true
	return false


func get_item(item_id: String) -> Dictionary:
	var key := item_id.strip_edges()
	for entry in carried_items:
		if str(entry.get("id", "")) == key:
			return entry.duplicate(true)
	return {}


func get_items() -> Array:
	var result: Array = []
	for entry in carried_items:
		result.append(entry.duplicate(true))
	return result


## Состояние предмета в мире: {"state": "placed|carried|dropped", "position": [x,y,z]}.
## Нужно, чтобы после загрузки коробка была в руках/на стойке, а не на спавне.
func get_item_state(item_id: String) -> Dictionary:
	var value: Variant = item_states.get(item_id, {})
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	return (value as Dictionary).duplicate(true)


func set_item_state(item_id: String, item_state: Dictionary) -> void:
	var key := item_id.strip_edges()
	if key.is_empty():
		return
	item_states[key] = item_state.duplicate(true)
	state_changed.emit()
	_autosave()


func clear_item_state(item_id: String) -> void:
	var key := item_id.strip_edges()
	if not item_states.has(key):
		return
	item_states.erase(key)
	state_changed.emit()
	_autosave()


# --- Сохранение / загрузка --------------------------------------------------


func to_dict() -> Dictionary:
	return {
		"objective": current_objective,
		"flags": flags.duplicate(true),
		"ending_id": ending_id,
		"ending_title": ending_title,
		"completed": completed,
		"stage_id": stage_id,
		"inventory": get_items(),
		"item_states": item_states.duplicate(true),
	}


## Загружает состояние. Совместим со старым форматом без stage_id/inventory:
## стадия выводится из flags, предметы — из флагов item_*.
func from_dict(data: Dictionary, emit_events: bool = true) -> void:
	if data.is_empty():
		return
	_loading = true
	current_objective = str(data.get("objective", current_objective))
	var saved_flags: Variant = data.get("flags", {})
	if typeof(saved_flags) == TYPE_DICTIONARY:
		flags = (saved_flags as Dictionary).duplicate(true)
	ending_id = int(data.get("ending_id", 0))
	ending_title = str(data.get("ending_title", ""))
	completed = bool(data.get("completed", false))

	carried_items = _parse_items(data.get("inventory", []))
	if carried_items.is_empty():
		_derive_inventory_from_flags()
	var saved_item_states: Variant = data.get("item_states", {})
	if typeof(saved_item_states) == TYPE_DICTIONARY:
		item_states = (saved_item_states as Dictionary).duplicate(true)
	else:
		item_states.clear()

	# Стадия: явная из нового сейва, но не откатываемся назад относительно флагов.
	var target_index := _stage_index(str(data.get("stage_id", "")))
	target_index = maxi(target_index, _derived_stage_index())
	if completed:
		target_index = STAGES.size() - 1
	if target_index < 0:
		target_index = 0
	stage_id = str((STAGES[target_index] as Dictionary).get("id", DEFAULT_STAGE_ID))
	if current_objective.strip_edges().is_empty():
		current_objective = get_current_stage_title()
	_loading = false

	if emit_events:
		objective_changed.emit(current_objective)
		stage_changed.emit(stage_id, get_current_stage_title())
		inventory_changed.emit(get_items())
		state_changed.emit()
		if completed and ending_id > 0:
			ending_reached.emit(ending_id, ending_title)


# --- Внутреннее -------------------------------------------------------------


func _stage_index(id: String) -> int:
	if id.is_empty():
		return -1
	for index in STAGES.size():
		if str((STAGES[index] as Dictionary).get("id", "")) == id:
			return index
	return -1


## Индекс стадии, выводимый из текущих флагов (для старых сейвов и загрузки).
func _derived_stage_index() -> int:
	var best := 0
	for entry in STAGE_FLAGS:
		var flag := str((entry as Dictionary).get("flag", ""))
		if not has_flag(flag):
			continue
		var index := _stage_index(str((entry as Dictionary).get("stage", "")))
		if index > best:
			best = index
	if completed:
		best = STAGES.size() - 1
	return best


## Двигает стадию вперёд по флагам; назад не откатывает.
func _sync_stage_from_flags() -> void:
	if _loading:
		return
	var derived := _derived_stage_index()
	if derived > _stage_index(stage_id):
		var derived_id := str((STAGES[derived] as Dictionary).get("id", stage_id))
		_apply_stage(derived_id, true, false)


func _apply_stage(new_stage_id: String, update_objective: bool, autosave: bool) -> void:
	var index := _stage_index(new_stage_id)
	if index < 0:
		return
	stage_id = new_stage_id
	var title := str((STAGES[index] as Dictionary).get("title", current_objective))
	if update_objective and current_objective != title:
		current_objective = title
		objective_changed.emit(current_objective)
	stage_changed.emit(stage_id, title)
	state_changed.emit()
	if autosave:
		_autosave()


func _set_item_flag(item_id: String, value: bool) -> void:
	var key := "item_%s" % item_id
	if flags.get(key, false) == value:
		return
	flags[key] = value
	flag_changed.emit(key, value)
	state_changed.emit()


func _parse_items(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if typeof(value) != TYPE_ARRAY:
		return result
	for entry in (value as Array):
		var item_id := ""
		var item_name := ""
		if typeof(entry) == TYPE_DICTIONARY:
			item_id = str((entry as Dictionary).get("id", "")).strip_edges()
			item_name = str((entry as Dictionary).get("name", "")).strip_edges()
		elif typeof(entry) == TYPE_STRING:
			item_id = str(entry).strip_edges()
		if item_id.is_empty():
			continue
		if item_name.is_empty():
			item_name = str(ITEM_NAMES.get(item_id, item_id))
		result.append({"id": item_id, "name": item_name})
	return result


## Миграция старых сейвов: предмет — это флаг item_* (см. библию §7.1).
func _derive_inventory_from_flags() -> void:
	carried_items.clear()
	for key in flags.keys():
		var flag := str(key)
		if not flag.begins_with("item_") or not has_flag(flag):
			continue
		var item_id := flag.substr(5)
		if item_id.is_empty():
			continue
		carried_items.append({
			"id": item_id,
			"name": str(ITEM_NAMES.get(item_id, item_id)),
		})


func _autosave() -> void:
	if _loading or not auto_save_enabled:
		return
	SaveSystem.autosave()
