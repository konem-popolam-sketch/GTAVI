extends Node
## DialogueManager — автолоад логики диалогов (см. scripts/dialogue/data/*.json).
##
## Запуск: start("mila", npc) или автоматически по сигналу NPC.interacted —
## менеджер сам подключается к узлам группы "npc" и берёт npc.get_dialogue_id().
## Управление: E — дальше/закрыть, 1–3 — выбор ответа (на финале выбор обязателен).
## На время диалога управление игроком и RayCast-интерактор отключаются,
## курсор отпускается; после закрытия — возвращаются.
##
## Сигналы:
##   dialogue_started(dialogue_id, npc)
##   line_changed(dialogue_id, node_id, speaker, text, choices)
##   dialogue_ended(dialogue_id, ending_id)   # ending_id=0 — обычный диалог
##
## Публичный API:
##   start(dialogue_id, npc = null) -> bool
##   advance(); choose(index); close()
##   is_active(); get_dialogue_id(); get_current_node_id(); get_current_speaker()
##   get_current_text(); get_choices(); get_npc(); has_choices(); has_next_line()
##   get_progress_text(); get_dialogue_ids(); reload_dialogues()

signal dialogue_started(dialogue_id: String, npc: Node)
signal line_changed(dialogue_id: String, node_id: String, speaker: String, text: String, choices: Array)
signal dialogue_ended(dialogue_id: String, ending_id: int)

const PLAYER_GROUP := "player"
const CHOICE_KEYS := {
	KEY_1: 0, KEY_2: 1, KEY_3: 2,
	KEY_KP_1: 0, KEY_KP_2: 1, KEY_KP_3: 2,
}
## Пауза перед повторным включением интерактора после закрытия диалога.
## Без неё то же нажатие E, которым закрыли последнюю реплику, в том же кадре
## попадает в RayCast-интерактор и открывает разговор заново — диалог «зацикливается».
const INTERACT_REOPEN_DELAY := 0.35

## Автоматически подключаться к NPC из группы "npc" (диалог по их interacted).
var auto_wire_npcs: bool = true
## Отключать управление игроком и интерактор на время диалога.
var auto_manage_player: bool = true

var _dialogues: Dictionary = {}
var _active: bool = false
var _dialogue_id: String = ""
var _node_id: String = ""
var _npc: Node = null
var _choices: Array = []
var _visited: int = 0
var _pending_ending: int = 0
var _pending_ending_title: String = ""
var _wired_npc_ids: Dictionary = {}
var _input_lock_frame: int = -1
## Поколение кулдауна интерактора: каждое закрытие диалога инвалидирует
## предыдущий отложенный возврат, чтобы наложившиеся таймеры не включали
## интерактор раньше срока или не оставляли его выключенным.
var _interact_reopen_generation: int = 0


func _ready() -> void:
	_dialogues = DialogueData.load_all(true)
	print("[dialogue] менеджер готов: диалогов %d" % _dialogues.size())
	if auto_wire_npcs:
		get_tree().node_added.connect(_on_node_added)
		call_deferred("_wire_all_npcs")


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	# Esc всегда выпускает из диалога, даже с узла с выбором, где E намеренно
	# не срабатывает: иначе на развилке разговор выглядит «зацикленным».
	if event.is_action_pressed("pause"):
		close()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("interact"):
		# Тот же E, которым открыли диалог, не должен сразу закрыть первую реплику.
		if Engine.get_process_frames() <= _input_lock_frame:
			return
		advance()
		get_viewport().set_input_as_handled()
		return
	if _choices.is_empty():
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		var index: int = CHOICE_KEYS.get(key_event.physical_keycode, -1)
		if index < 0:
			index = CHOICE_KEYS.get(key_event.keycode, -1)
		if index >= 0 and index < _choices.size():
			choose(index)
			get_viewport().set_input_as_handled()


# --- Публичный API ----------------------------------------------------------


## Начать диалог по id. Возвращает false, если диалог уже идёт или id неизвестен.
func start(dialogue_id: String, npc: Node = null) -> bool:
	if _active:
		return false
	var dialogue := _get_dialogue(dialogue_id)
	if dialogue.is_empty():
		push_warning("[dialogue] неизвестный диалог '%s'" % dialogue_id)
		return false
	var nodes: Dictionary = dialogue.get("nodes", {})
	var start_id := DialogueData.get_start_node(dialogue)
	if start_id.is_empty() or not nodes.has(start_id):
		push_warning("[dialogue] у диалога '%s' нет стартового узла" % dialogue_id)
		return false
	_active = true
	_dialogue_id = dialogue_id
	_npc = npc
	print("[dialogue] start '%s' npc=%s" % [dialogue_id, "null" if npc == null else str(npc.name)])
	_visited = 0
	_choices = []
	_pending_ending = 0
	_pending_ending_title = ""
	_input_lock_frame = Engine.get_process_frames()
	_set_player_controls(false)
	dialogue_started.emit(_dialogue_id, _npc)
	_enter_node(start_id)
	return true


## Следующая реплика или закрытие, если реплика последняя. На узле с выбором
## (choices) E игнорируется — сначала нужно choose(index).
func advance() -> void:
	if not _active or not _choices.is_empty():
		return
	var node := _current_node()
	var next_id := _as_string(node.get("next", ""))
	if next_id.is_empty():
		close()
	else:
		_enter_node(next_id)


## Выбрать вариант ответа (0-based). После выбора идём по choice.next.
func choose(index: int) -> void:
	if not _active or _choices.is_empty():
		return
	if index < 0 or index >= _choices.size():
		return
	var choice_variant: Variant = _choices[index]
	if typeof(choice_variant) != TYPE_DICTIONARY:
		return
	var choice: Dictionary = choice_variant
	var next_id := _as_string(choice.get("next", ""))
	_choices = []
	if next_id.is_empty():
		close()
	else:
		_enter_node(next_id)


func close() -> void:
	if not _active:
		return
	var finished_id := _dialogue_id
	var ending_id := _pending_ending
	var ending_title := _pending_ending_title
	_active = false
	_dialogue_id = ""
	_node_id = ""
	_npc = null
	_choices = []
	_visited = 0
	_pending_ending = 0
	_pending_ending_title = ""
	# Интерактор возвращает только кулдаун ниже — иначе после закрытия было бы
	# два включения (сразу и через 0.35 с) и гонка с повторным открытием.
	_set_player_controls(true, false)
	_guard_interaction_reopen()
	dialogue_ended.emit(finished_id, ending_id)
	if ending_id > 0:
		var quest := get_node_or_null("/root/QuestState")
		if quest != null and quest.has_method("set_ending"):
			quest.set_ending(ending_id, ending_title)


func is_active() -> bool:
	return _active


func get_dialogue_id() -> String:
	return _dialogue_id


func get_current_node_id() -> String:
	return _node_id


func get_current_speaker() -> String:
	if not _active:
		return ""
	return str(_current_node().get("speaker", _current_dialogue().get("speaker", "")))


func get_current_text() -> String:
	if not _active:
		return ""
	return str(_current_node().get("text", ""))


func get_choices() -> Array:
	return _choices.duplicate(true)


func get_npc() -> Node:
	return _npc


func has_choices() -> bool:
	return not _choices.is_empty()


func has_next_line() -> bool:
	if not _active:
		return false
	var next_id := _as_string(_current_node().get("next", ""))
	return not next_id.is_empty()


func get_progress_text() -> String:
	if not _active:
		return ""
	return "реплика %d" % maxi(_visited, 1)


func get_dialogue_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for key in _dialogues.keys():
		ids.append(str(key))
	return ids


func reload_dialogues() -> void:
	_dialogues = DialogueData.load_all(true)


# --- Внутреннее -------------------------------------------------------------


func _enter_node(node_id: String) -> void:
	var dialogue := _current_dialogue()
	var nodes: Dictionary = dialogue.get("nodes", {})
	if not nodes.has(node_id):
		push_warning("[dialogue] '%s': нет узла '%s'" % [_dialogue_id, node_id])
		close()
		return
	_node_id = node_id
	_visited += 1
	var node_variant: Variant = nodes[node_id]
	var node: Dictionary = node_variant if typeof(node_variant) == TYPE_DICTIONARY else {}
	_apply_effect(node.get("effect", {}))
	if node.has("ending"):
		var ending := int(node.get("ending", 0))
		if ending > 0:
			_pending_ending = ending
			_pending_ending_title = str(node.get("ending_title", ""))
	var choices_variant: Variant = node.get("choices", [])
	_choices = []
	if typeof(choices_variant) == TYPE_ARRAY:
		_choices = _filter_choices(choices_variant as Array)
	var speaker := str(node.get("speaker", dialogue.get("speaker", "")))
	line_changed.emit(_dialogue_id, _node_id, speaker, str(node.get("text", "")), _choices.duplicate(true))


func _current_dialogue() -> Dictionary:
	return _get_dialogue(_dialogue_id)


func _as_string(value: Variant) -> String:
	if value == null:
		return ""
	return str(value)


func _current_node() -> Dictionary:
	return DialogueData.get_node_data(_current_dialogue(), _node_id)


func _get_dialogue(dialogue_id: String) -> Dictionary:
	if _dialogues.has(dialogue_id):
		return _dialogues[dialogue_id]
	# Контент мог быть перезагружен/добавлен после _ready.
	_dialogues = DialogueData.load_all()
	return _dialogues.get(dialogue_id, {})


## Фильтр вариантов ответа по "requires": ["flag", …] (библия §7.2).
## Если хотя бы одного флага нет — вариант не показывается; индексы оставшихся
## вариантов уплотняются, поэтому 1–3 в UI всегда соответствуют видимым строкам.
func _filter_choices(choices: Array) -> Array:
	var result: Array = []
	var quest := get_node_or_null("/root/QuestState")
	for choice_variant in choices:
		if typeof(choice_variant) != TYPE_DICTIONARY:
			result.append(choice_variant)
			continue
		var choice: Dictionary = choice_variant
		var requires: Variant = choice.get("requires", [])
		if quest != null and typeof(requires) == TYPE_ARRAY and not (requires as Array).is_empty():
			var allowed := true
			for flag_variant in (requires as Array):
				if not quest.has_flag(str(flag_variant)):
					allowed = false
					break
			if not allowed:
				continue
		result.append(choice.duplicate(true))
	return result


func _apply_effect(effect_variant: Variant) -> void:
	if typeof(effect_variant) != TYPE_DICTIONARY or (effect_variant as Dictionary).is_empty():
		return
	var quest := get_node_or_null("/root/QuestState")
	if quest == null:
		return
	var effect: Dictionary = effect_variant
	if effect.has("objective") and quest.has_method("set_objective"):
		quest.set_objective(str(effect["objective"]))
	if effect.has("set_flag") and quest.has_method("set_flag"):
		var flag: Variant = effect["set_flag"]
		if typeof(flag) == TYPE_ARRAY:
			for item in flag:
				quest.set_flag(str(item), true)
		else:
			quest.set_flag(str(flag), true)
	if effect.has("flags") and quest.has_method("set_flag"):
		var flags: Variant = effect["flags"]
		if typeof(flags) == TYPE_DICTIONARY:
			for key in (flags as Dictionary).keys():
				quest.set_flag(str(key), (flags as Dictionary)[key])


func _set_player_controls(enabled: bool, manage_interactor: bool = true) -> void:
	if not auto_manage_player:
		return
	var loop := Engine.get_main_loop()
	if loop is not SceneTree:
		return
	var player := (loop as SceneTree).get_first_node_in_group(PLAYER_GROUP)
	if player == null:
		return
	if player.has_method("set_controls_enabled"):
		player.set_controls_enabled(enabled)
	if player.has_method("set_mouse_captured"):
		player.set_mouse_captured(enabled)
	if manage_interactor and player.has_method("get_interactor"):
		var interactor: Variant = player.get_interactor()
		if interactor != null and interactor.has_method("set_interaction_enabled"):
			interactor.set_interaction_enabled(enabled)


## Гасим интерактор на короткое время после закрытия диалога, чтобы нажатие E,
## закрывшее последнюю реплику, не открыло разговор заново в том же кадре.
func _guard_interaction_reopen() -> void:
	_interact_reopen_generation += 1
	var generation := _interact_reopen_generation
	if not auto_manage_player:
		return
	var loop := Engine.get_main_loop()
	if loop is not SceneTree:
		return
	var player := (loop as SceneTree).get_first_node_in_group(PLAYER_GROUP)
	if player == null or not player.has_method("get_interactor"):
		return
	var interactor: Variant = player.get_interactor()
	if interactor == null or not interactor.has_method("set_interaction_enabled"):
		return
	interactor.set_interaction_enabled(false)
	await (loop as SceneTree).create_timer(INTERACT_REOPEN_DELAY).timeout
	# Пока таймер спал, диалог могли закрыть ещё раз — тогда включать интерактор
	# должен только таймер последнего закрытия.
	if generation != _interact_reopen_generation:
		return
	if _active or not is_instance_valid(interactor):
		return
	interactor.set_interaction_enabled(true)


# --- Автоподключение NPC ----------------------------------------------------


func _wire_all_npcs() -> void:
	for npc in get_tree().get_nodes_in_group("npc"):
		_wire_npc(npc)


func _on_node_added(node: Node) -> void:
	if node.is_in_group("npc"):
		_wire_npc(node)
	else:
		# Передаём instance_id, а не Node: к моменту отложенного вызова узел
		# может быть уже удалён, и типизированный аргумент Node падал бы на
		# конвертации ещё до входа в _wire_late_npc.
		call_deferred("_wire_late_npc", node.get_instance_id())


func _wire_late_npc(instance_id: int) -> void:
	# Поздние узлы привязываем только во время активного диалога: после его
	# закрытия это уже не нужно и раньше давало гонку с уже отвязанным NPC.
	if not _active:
		return
	if not is_instance_id_valid(instance_id):
		return
	var node := instance_from_id(instance_id) as Node
	if node == null or node.is_queued_for_deletion() or not node.is_in_group("npc"):
		return
	_wire_npc(node)


func _wire_npc(npc: Node) -> void:
	if npc == null or not is_instance_valid(npc):
		return
	var id := npc.get_instance_id()
	if _wired_npc_ids.has(id):
		return
	if not npc.has_signal("interacted"):
		return
	_wired_npc_ids[id] = true
	var callback := Callable(self, "_on_npc_interacted")
	if npc.is_connected("interacted", callback):
		return
	npc.interacted.connect(callback)


func _on_npc_interacted(npc: Node, player: Node = null) -> void:
	if not auto_wire_npcs or _active:
		return
	var dialogue_id := ""
	if npc != null and is_instance_valid(npc):
		if npc.has_method("get_dialogue_id"):
			dialogue_id = str(npc.get_dialogue_id())
		elif npc.has_meta("dialogue_id"):
			dialogue_id = str(npc.get_meta("dialogue_id"))
	if dialogue_id.is_empty():
		return
	start(dialogue_id, npc)
