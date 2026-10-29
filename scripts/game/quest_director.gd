class_name QuestDirector
extends Node
## QuestDirector — «реакция мира» на сюжетные флаги: переключает dialogue_id
## у NPC по акту, гасит неон «Луны» после второй точки и закрывает/открывает
## шлагбаум.
##
## Это необязательный узел интеграции (t20): добавь Node с этим скриптом в
## scenes/main.tscn (например, рядом с Npcs). Если узла нет, квест всё равно
## работает — просто NPC не меняют реплики сами.
##
## Правила (docs/story_bible.md §2, §7.3):
##   mila:    twin_box_found -> mila_late; night_started -> Мила ушла (скрыта);
##            иначе mila.
##   foreman: mila_confessed -> foreman_late (у машины); night_started -> ушёл
##            с пирса (скрыт); иначе foreman.
##   kostya:  foreman_cornered -> kostya_late; иначе kostya.
##   voice:   kostya_witness -> finale; night_started -> voice_log; иначе voice.
##   Неон «Луны» (группа neon_sign) гаснет при twin_box_found.
##   Шлагбаум (группа night_gate) закрыт при night_started, открыт при
##   ending_shift (третья концовка).
##
## Публичный API:
##   resolve_dialogue(npc_id) -> Dictionary
##       {"dialogue": "mila_late", "hidden": false} или {"dialogue": "", "hidden": true}
##   apply_now() — применить правила вручную
## Сигналы:
##   dialogue_switched(npc_id, dialogue_id)   # dialogue_id="" — NPC скрыт
##   barrier_changed(closed)
##   neon_changed(enabled)

signal dialogue_switched(npc_id: String, dialogue_id: String)
signal barrier_changed(closed: bool)
signal neon_changed(enabled: bool)

## npc_id -> список правил [флаг, dialogue_id, скрыть?], проверяются сверху вниз.
const NPC_RULES := {
	"mila": [
		{"flag": "twin_box_found", "dialogue": "mila_late", "hidden": false},
		{"flag": "night_started", "dialogue": "", "hidden": true},
	],
	"foreman": [
		{"flag": "mila_confessed", "dialogue": "foreman_late", "hidden": false},
		{"flag": "night_started", "dialogue": "", "hidden": true},
	],
	"kostya": [
		{"flag": "foreman_cornered", "dialogue": "kostya_late", "hidden": false},
	],
	"voice": [
		{"flag": "kostya_witness", "dialogue": "finale", "hidden": false},
		{"flag": "night_started", "dialogue": "voice_log", "hidden": false},
	],
}

@export var auto_apply: bool = true
## Скрывать NPC, у которых по сюжету нет реплик (Мила ушла в подсобку и т.п.).
@export var hide_silent_npcs: bool = true

var _applied_dialogues: Dictionary = {}
var _npc_layers: Dictionary = {}
var _neon_energy: Dictionary = {}
var _neon_applied: int = -1
var _barrier_applied: int = -1


func _ready() -> void:
	var quest := get_node_or_null("/root/QuestState")
	if quest != null:
		if quest.has_signal("flag_changed"):
			quest.flag_changed.connect(_on_quest_changed)
		if quest.has_signal("state_changed"):
			quest.state_changed.connect(_on_quest_changed)
	if auto_apply:
		call_deferred("apply_now")


func _on_quest_changed(_a: Variant = null, _b: Variant = null) -> void:
	if auto_apply:
		apply_now()


## Чистое правило по id NPC (без обращения к узлам) — удобно для тестов.
func resolve_dialogue(npc_id: String) -> Dictionary:
	var quest := get_node_or_null("/root/QuestState")
	var default_dialogue := ""
	match npc_id:
		"mila":
			default_dialogue = "mila"
		"kostya":
			default_dialogue = "kostya"
		"foreman":
			default_dialogue = "foreman"
		"voice":
			default_dialogue = "voice"
	if quest == null:
		return {"dialogue": default_dialogue, "hidden": false}
	var rules: Array = NPC_RULES.get(npc_id, [])
	for rule_variant in rules:
		var rule: Dictionary = rule_variant
		if not quest.has_flag(str(rule.get("flag", ""))):
			continue
		var dialogue_id := str(rule.get("dialogue", default_dialogue))
		if dialogue_id.is_empty() and hide_silent_npcs:
			return {"dialogue": "", "hidden": true}
		return {"dialogue": dialogue_id, "hidden": bool(rule.get("hidden", false))}
	return {"dialogue": default_dialogue, "hidden": false}


func apply_now() -> void:
	var quest := get_node_or_null("/root/QuestState")
	if quest == null:
		return
	_apply_npcs()
	_apply_neon(not quest.has_flag("twin_box_found"))
	_apply_barrier(quest.has_flag("night_started") and not quest.has_flag("ending_shift"))


# --- Внутреннее -------------------------------------------------------------


func _apply_npcs() -> void:
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group("npc"):
		var npc := node as Node3D
		if npc == null or not is_instance_valid(npc):
			continue
		var npc_id := ""
		if npc.has_method("get_dialogue_id"):
			npc_id = _read_npc_id(npc)
		if npc_id.is_empty():
			continue
		var resolved := resolve_dialogue(npc_id)
		var hidden := bool(resolved.get("hidden", false))
		var dialogue_id := str(resolved.get("dialogue", ""))
		_set_npc_hidden(npc, hidden)
		if hidden or dialogue_id.is_empty():
			continue
		var current := ""
		if npc.has_method("get_dialogue_id"):
			current = str(npc.call("get_dialogue_id"))
		elif npc.has_meta("dialogue_id"):
			current = str(npc.get_meta("dialogue_id"))
		if current == dialogue_id and _applied_dialogues.get(npc_id, "") == dialogue_id:
			continue
		_apply_dialogue_to_npc(npc, npc_id, dialogue_id)


func _read_npc_id(npc: Node3D) -> String:
	if npc.has_meta("npc_id"):
		return str(npc.get_meta("npc_id"))
	var value: Variant = npc.get("npc_id")
	if value != null:
		return str(value)
	return ""


func _apply_dialogue_to_npc(npc: Node3D, npc_id: String, dialogue_id: String) -> void:
	for info in npc.get_property_list():
		if str(info.get("name", "")) == "dialogue_id":
			npc.set("dialogue_id", dialogue_id)
			break
	npc.set_meta("dialogue_id", dialogue_id)
	_applied_dialogues[npc_id] = dialogue_id
	dialogue_switched.emit(npc_id, dialogue_id)


func _set_npc_hidden(npc: Node3D, hidden: bool) -> void:
	var key := npc.get_instance_id()
	if not _npc_layers.has(key):
		_npc_layers[key] = npc.collision_layer
	var target_layer := 0 if hidden else int(_npc_layers[key])
	if npc.collision_layer == target_layer and npc.visible == not hidden:
		return
	npc.visible = not hidden
	npc.collision_layer = target_layer


func _apply_neon(enabled: bool) -> void:
	var state := 1 if enabled else 0
	if _neon_applied == state:
		return
	_neon_applied = state
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group("neon_sign"):
		if not is_instance_valid(node):
			continue
		var key := node.get_instance_id()
		if not _neon_energy.has(key) and node is Light3D:
			_neon_energy[key] = (node as Light3D).light_energy
		if node is Light3D:
			var light := node as Light3D
			light.light_energy = float(_neon_energy.get(key, light.light_energy)) if enabled else 0.0
		elif node is Node3D:
			(node as Node3D).visible = enabled
	neon_changed.emit(enabled)


func _apply_barrier(closed: bool) -> void:
	var state := 1 if closed else 0
	if _barrier_applied == state:
		return
	_barrier_applied = state
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group("night_gate"):
		if not is_instance_valid(node):
			continue
		if node.has_method("set_gate_closed"):
			node.call("set_gate_closed", closed)
		elif node is Node3D:
			# Универсальный запасной путь: наклонять узел шлагбаума.
			(node as Node3D).rotation.z = 0.0 if not closed else deg_to_rad(90.0)
	barrier_changed.emit(closed)
