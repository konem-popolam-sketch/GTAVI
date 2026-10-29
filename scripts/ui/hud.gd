extends Control
## HUD v2 — верхняя панель с шагом квеста, счётчик найденного, подсказка
## взаимодействия снизу по центру, квест-лог по Tab и титр «КОНЕЦ».
##
## Стиль: ночной неон (cyan/magenta), тёмное стекло — те же StyleBoxFlat, что
## были в v1. HUD сам подключается к автолоадам, интегратору достаточно держать
## ui/hud.tscn под CanvasLayer (см. отчёт t17 о точном месте в дереве).
##
## Скрытие: в диалоге, на паузе и на титульной плашке панели исчезают
## (пауза дергает set_paused(true) через группу "hud").
##
## Graceful fallback: если у QuestState ещё нет stage_changed / get_stage_title
## (t16 идёт параллельно), HUD работает по objective_changed, флагам и стадиям
## внутри QUEST_STAGES.
##
## Публичный API:
##   set_objective(text); refresh()
##   show_hint(text = "E — поговорить"); hide_hint()
##   show_ending(ending_id, title); hide_ending()
##   set_paused(value); is_paused()
##   toggle_quest_log(force = null); is_quest_log_open()

const UiSettings = preload("res://scripts/ui/ui_settings.gd")

const HINT_TALK := "E — поговорить"
const HINT_TAKE := "E — взять"
const OBJECTIVE_FALLBACK := "Осмотрись в квартале"
const OBJECTIVE_PREFIX := "ЦЕЛЬ: "
const HUD_GROUP := "hud"

## Стадии квеста для лога и счётчика. Стадия засчитывается, если выполнен хотя
## бы один из её флагов (имена — из docs/story_tasks.md и docs/story_bible.md).
const QUEST_STAGES := [
	{"title": "Взять посылку у Милы", "flags": ["mila_warned"]},
	{"title": "Ответить автоответчику", "flags": ["package_delivered", "night_started"]},
	{"title": "Подняться в диспетчерскую над «Луной»", "flags": ["shift_log_seen", "galya_deal"]},
	{"title": "Найти код от стройки у сторожа", "flags": ["site_code", "timur_friend"]},
	{"title": "Обыскать подвал стройки", "flags": ["twin_box_found"]},
	{"title": "Вернуться к Миле у витрины", "flags": ["mila_confessed", "mila_promise"]},
	{"title": "Поговорить с Прорабом", "flags": ["foreman_cornered"]},
	{"title": "Поговорить с Костей", "flags": ["kostya_witness", "kostya_told"]},
	{"title": "Решить судьбу коробки", "flags": ["ending_silence", "ending_voice", "ending_shift"]},
]

@onready var objective_panel: Control = $ObjectivePanel
@onready var objective_label: Label = $ObjectivePanel/ObjectiveLabel
@onready var counter_panel: Control = $CounterPanel
@onready var counter_label: Label = $CounterPanel/CounterLabel
@onready var hint_panel: Control = $HintPanel
@onready var hint_label: Label = $HintPanel/HintLabel
@onready var quest_log_overlay: Control = $QuestLogOverlay
@onready var quest_stages_box: VBoxContainer = $QuestLogOverlay/Center/Panel/Margin/VBox/StagesBox
@onready var quest_log_hint: Label = $QuestLogOverlay/Center/Panel/Margin/VBox/CloseHintLabel
@onready var ending_overlay: Control = $EndingOverlay
@onready var ending_number_label: Label = $EndingOverlay/Center/VBox/EndingNumberLabel
@onready var ending_name_label: Label = $EndingOverlay/Center/VBox/EndingNameLabel

var _quest = null
var _player: Player = null
var _title_card: Node = null
var _current_target: Node = null
var _dialogue_open: bool = false
var _ending_visible: bool = false
var _title_card_open: bool = false
var _paused: bool = false
var _quest_log_open: bool = false
var _ending_froze_player: bool = false
var _last_hint: String = HINT_TALK
## Label3D (имена NPC) рисуется в 3D-проходе и не гаснет под CanvasLayer-затемнением
## титра, поэтому на время «КОНЦА» подписи скрываются, после — возвращаются.
var _hidden_ending_labels: Array[Dictionary] = []


func _ready() -> void:
	add_to_group(HUD_GROUP)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiSettings.ensure_loaded()
	_quest = get_node_or_null("/root/QuestState")
	hide_hint()
	hide_ending()
	quest_log_overlay.visible = false
	objective_label.max_lines_visible = 2
	objective_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_connect_quest_state()
	_connect_dialogue_manager()
	_apply_accessibility()
	refresh()
	call_deferred("_bind_player")
	call_deferred("_bind_title_card")


# --- Публичный API ----------------------------------------------------------


func refresh() -> void:
	set_objective(_read_objective())
	_refresh_progress()
	_refresh_quest_log()


func set_objective(text: String) -> void:
	var value := text.strip_edges()
	if value.is_empty():
		value = OBJECTIVE_FALLBACK
	objective_label.text = OBJECTIVE_PREFIX + value


func show_hint(text: String = HINT_TALK) -> void:
	if _hint_suppressed():
		return
	_last_hint = text
	hint_label.text = text
	hint_panel.visible = UiSettings.hints_visible


func hide_hint() -> void:
	hint_panel.visible = false


func set_paused(value: bool) -> void:
	_paused = value
	visible = not value
	_update_visibility()
	if value:
		_close_quest_log()


func is_paused() -> bool:
	return _paused


## Титульная плашка ещё висит (HUD сам её находит и прячется).
func is_title_open() -> bool:
	return _title_card_open


func show_ending(ending_id: int, title: String) -> void:
	_ending_visible = true
	_hide_npc_name_labels()
	ending_overlay.visible = true
	ending_overlay.modulate.a = 0.0
	ending_number_label.text = "КОНЦОВКА %d" % ending_id
	ending_name_label.text = title if not title.is_empty() else "—"
	hide_hint()
	_close_quest_log()
	if _player != null and not _ending_froze_player:
		_ending_froze_player = true
		_player.set_controls_enabled(false)
		_player.set_mouse_captured(false)
	var tween := create_tween()
	tween.tween_property(ending_overlay, "modulate:a", 1.0, 0.7)


func hide_ending() -> void:
	_ending_visible = false
	_restore_npc_name_labels()
	if _ending_froze_player and _player != null:
		_player.set_controls_enabled(true)
		_player.set_mouse_captured(true)
	_ending_froze_player = false
	ending_overlay.visible = false
	ending_overlay.modulate.a = 1.0
	_update_visibility()


func toggle_quest_log(force: Variant = null) -> void:
	var next_state := not _quest_log_open
	if force != null:
		next_state = bool(force)
	if next_state == _quest_log_open:
		return
	_quest_log_open = next_state
	if next_state:
		_refresh_quest_log()
	_update_visibility()


func is_quest_log_open() -> bool:
	return _quest_log_open


## Перечитать доступность: шрифт/контраст меняются из паузы.
func apply_settings() -> void:
	_apply_accessibility()
	_update_visibility()


# --- Ввод: Tab — журнал квеста, M — подсказки -------------------------------


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if _dialogue_open or _ending_visible or _paused or _title_card_open:
		return
	var keycode := key_event.physical_keycode
	if keycode == 0:
		keycode = key_event.keycode
	if keycode == KEY_TAB:
		toggle_quest_log()
		get_viewport().set_input_as_handled()
	elif keycode == KEY_M:
		UiSettings.set_hints_visible(not UiSettings.hints_visible)
		_update_visibility()
		if UiSettings.hints_visible:
			show_hint(_last_hint)
		else:
			hide_hint()
		get_viewport().set_input_as_handled()


# --- Внутреннее: состояние и видимость --------------------------------------


func _hint_suppressed() -> bool:
	return _dialogue_open or _ending_visible or _paused or _title_card_open or not UiSettings.hints_visible


func _update_visibility() -> void:
	var hidden := _dialogue_open or _ending_visible or _paused or _title_card_open
	objective_panel.visible = not hidden
	counter_panel.visible = not hidden
	quest_log_overlay.visible = _quest_log_open and not hidden
	if hidden or not UiSettings.hints_visible:
		hint_panel.visible = false
	else:
		_refresh_hint()


func _refresh_hint() -> void:
	if _current_target == null or not is_instance_valid(_current_target):
		hint_panel.visible = false
		return
	hint_label.text = _hint_for_target(_current_target)
	hint_panel.visible = true


func _hint_for_target(target: Node) -> String:
	if target == null:
		return HINT_TALK
	if target.has_method("get_interact_hint"):
		var custom := str(target.call("get_interact_hint"))
		if not custom.is_empty():
			return custom
	if target.has_meta("interact_hint"):
		var meta_hint := str(target.get_meta("interact_hint"))
		if not meta_hint.is_empty():
			return meta_hint
	if target.is_in_group("npc") or target.has_method("get_dialogue_id") or target.has_method("interact_dialogue"):
		return HINT_TALK
	return HINT_TAKE


func _close_quest_log() -> void:
	if not _quest_log_open:
		return
	_quest_log_open = false
	quest_log_overlay.visible = false


# --- Внутреннее: квест-лог и счётчик ---------------------------------------


func _read_objective() -> String:
	if _quest == null:
		return OBJECTIVE_FALLBACK
	# t16: точный заголовок текущего шага; старые сборки — просто цель.
	for method in ["get_current_stage_title", "get_stage_title", "get_objective"]:
		if _quest.has_method(str(method)):
			var text := str(_quest.call(str(method))).strip_edges()
			if not text.is_empty():
				return text
	return OBJECTIVE_FALLBACK


func _has_flag(flag: String) -> bool:
	if _quest == null or not _quest.has_method("has_flag"):
		return false
	return bool(_quest.call("has_flag", flag))


func _quest_finished() -> bool:
	if _quest == null or not _quest.has_method("is_finished"):
		return false
	return bool(_quest.call("is_finished"))


## Стадии для лога и счётчика: приоритет — API QuestState (t16),
## запасной путь — локальный QUEST_STAGES, посчитанный по флагам.
func _stage_entries() -> Array:
	if _quest != null and _quest.has_method("get_stages"):
		var from_quest: Array = _quest.call("get_stages")
		if not from_quest.is_empty():
			return from_quest
	var entries: Array = []
	var current := -1
	for index in QUEST_STAGES.size():
		if not _legacy_stage_done(index):
			current = index
			break
	if current < 0:
		current = QUEST_STAGES.size() - 1
	for index in QUEST_STAGES.size():
		var stage: Dictionary = QUEST_STAGES[index]
		entries.append({
			"id": "legacy_%d" % index,
			"title": str(stage.get("title", "")),
			"completed": _legacy_stage_done(index),
			"active": index == current,
			"act": 0,
		})
	return entries


func _legacy_stage_done(index: int) -> bool:
	if index < 0 or index >= QUEST_STAGES.size():
		return false
	var stage: Dictionary = QUEST_STAGES[index]
	if index == QUEST_STAGES.size() - 1 and _quest_finished():
		return true
	var flags: Array = stage.get("flags", [])
	for flag in flags:
		if _has_flag(str(flag)):
			return true
	return false


func _stage_counts() -> Dictionary:
	var entries := _stage_entries()
	var done := 0
	for entry in entries:
		if typeof(entry) == TYPE_DICTIONARY and bool((entry as Dictionary).get("completed", false)):
			done += 1
	return {"done": done, "total": entries.size()}


func _refresh_progress() -> void:
	if counter_label == null:
		return
	var counts := _stage_counts()
	var text := "НАЙДЕНО %d/%d" % [int(counts["done"]), int(counts["total"])]
	var items := _item_count()
	if items > 0:
		text += " · ПРЕДМЕТОВ %d" % items
	counter_label.text = text


## Сколько предметов в инвентаре (t16), если API есть.
func _item_count() -> int:
	if _quest == null or not _quest.has_method("get_items"):
		return 0
	var items: Array = _quest.call("get_items")
	return items.size()


func _refresh_quest_log() -> void:
	if quest_stages_box == null:
		return
	for child in quest_stages_box.get_children():
		quest_stages_box.remove_child(child)
		child.queue_free()
	var entries := _stage_entries()
	var counts := _stage_counts()
	for index in entries.size():
		var entry: Dictionary = {}
		if typeof(entries[index]) == TYPE_DICTIONARY:
			entry = entries[index]
		var done := bool(entry.get("completed", false))
		var active := bool(entry.get("active", false))
		var label := Label.new()
		label.name = "Stage%d" % (index + 1)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mark := "✓" if done else ("▸" if active else "·")
		label.text = "%s %d. %s" % [mark, index + 1, str(entry.get("title", ""))]
		label.add_theme_font_size_override("font_size", 18)
		if done:
			label.add_theme_color_override("font_color", Color(0.45, 0.95, 0.85, 1.0))
		elif active:
			label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.6, 1.0))
		else:
			label.add_theme_color_override("font_color", Color(0.62, 0.7, 0.78, 1.0))
		quest_stages_box.add_child(label)
	if quest_log_hint != null:
		quest_log_hint.text = "Tab — закрыть · пройдено %d из %d" % [
			int(counts["done"]), int(counts["total"])
		]


# --- Доступность -------------------------------------------------------------


func _apply_accessibility() -> void:
	var hint_color := Color(1.0, 0.86, 0.55, 1.0)
	var hint_outline := Color(0.0, 0.0, 0.0, 0.65)
	var hint_outline_size := 0
	if UiSettings.high_contrast:
		hint_color = Color(1.0, 0.98, 0.9, 1.0)
		hint_outline = Color(0.0, 0.0, 0.0, 1.0)
		hint_outline_size = 6
	hint_label.add_theme_color_override("font_color", hint_color)
	hint_label.add_theme_color_override("font_outline_color", hint_outline)
	hint_label.add_theme_constant_override("outline_size", hint_outline_size)
	objective_label.add_theme_constant_override("line_spacing", 2)


# --- Привязка к игроку, титулу и автолоадам --------------------------------


func _bind_player() -> void:
	_player = get_tree().get_first_node_in_group("player") as Player
	if _player == null:
		return
	if not _player.interaction_target_changed.is_connected(_on_interaction_target_changed):
		_player.interaction_target_changed.connect(_on_interaction_target_changed)


func _bind_title_card() -> void:
	_title_card = _find_title_card()
	if _title_card == null:
		_title_card_open = false
		_update_visibility()
		return
	if _title_card.has_method("is_open"):
		_title_card_open = bool(_title_card.call("is_open"))
	if _title_card.has_signal("title_dismissed"):
		if not _title_card.is_connected("title_dismissed", Callable(self, "_on_title_dismissed")):
			_title_card.connect("title_dismissed", Callable(self, "_on_title_dismissed"))
	_update_visibility()


func _find_title_card() -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var found := scene.find_child("TitleCard", true, false)
	if found != null and found.has_method("is_open"):
		return found
	# Запасной путь: любой узел с API титульной плашки.
	for node in get_tree().get_nodes_in_group("title_card"):
		if node.has_method("is_open"):
			return node
	return null


func _connect_quest_state() -> void:
	if _quest == null:
		return
	if _quest.has_signal("objective_changed"):
		_quest.connect("objective_changed", Callable(self, "_on_objective_changed"))
	if _quest.has_signal("flag_changed"):
		_quest.connect("flag_changed", Callable(self, "_on_quest_signal"))
	if _quest.has_signal("state_changed"):
		_quest.connect("state_changed", Callable(self, "_on_quest_signal"))
	if _quest.has_signal("ending_reached"):
		_quest.connect("ending_reached", Callable(self, "_on_ending_reached"))
	# t16 может добавить stage_changed — подключаемся только если он есть.
	if _quest.has_signal("stage_changed"):
		_quest.connect("stage_changed", Callable(self, "_on_quest_signal"))


func _connect_dialogue_manager() -> void:
	var manager := get_node_or_null("/root/DialogueManager")
	if manager == null:
		return
	if manager.has_signal("dialogue_started"):
		manager.connect("dialogue_started", Callable(self, "_on_dialogue_started"))
	if manager.has_signal("dialogue_ended"):
		manager.connect("dialogue_ended", Callable(self, "_on_dialogue_ended"))


# --- Обработчики -------------------------------------------------------------


func _on_interaction_target_changed(target: Node) -> void:
	_current_target = target
	if target == null or _hint_suppressed():
		hide_hint()
	else:
		show_hint(_hint_for_target(target))


func _on_objective_changed(text: String) -> void:
	set_objective(text)


## Общий приёмник сигналов QuestState с разным числом аргументов
## (flag_changed(2), state_changed(0), stage_changed(?) — t16 идёт параллельно).
func _on_quest_signal(_a = null, _b = null, _c = null, _d = null, _e = null) -> void:
	refresh()


func _on_ending_reached(ending_id: int, title: String) -> void:
	show_ending(ending_id, title)


func _on_dialogue_started(_dialogue_id: String, _npc: Node) -> void:
	_dialogue_open = true
	_close_quest_log()
	_update_visibility()


func _on_dialogue_ended(_dialogue_id: String, _ending_id: int) -> void:
	_dialogue_open = false
	_update_visibility()
	if _current_target != null and not _ending_visible:
		show_hint(_hint_for_target(_current_target))


func _on_title_dismissed() -> void:
	_title_card_open = false
	_update_visibility()


# --- Титр «КОНЕЦ»: подписи NPC ----------------------------------------------


func _hide_npc_name_labels() -> void:
	for npc in get_tree().get_nodes_in_group("npc"):
		for node in npc.find_children("*", "Label3D", true, false):
			var label := node as Label3D
			if label == null or not label.visible:
				continue
			_hidden_ending_labels.append({"label": label, "was_visible": true})
			label.visible = false


func _restore_npc_name_labels() -> void:
	for entry in _hidden_ending_labels:
		var label: Label3D = entry.get("label") as Label3D
		if is_instance_valid(label):
			label.visible = bool(entry.get("was_visible", true))
	_hidden_ending_labels.clear()
