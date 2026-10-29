class_name TwinBox
extends Area3D
## Вторая коробка на стройке — предмет, который закрывает стадию inspect_twin_box.
##
## Корень — Area3D с высоким объёмом взаимодействия (0.9×1.7×0.9): луч интерактора
## идёт из камеры на высоте ~1.5 м, и низкий ящик он бы просто не задел. Area3D
## не мешает ходить, а физический объём ящика висит отдельным StaticBody3D внутри.
##
## Сделан по контракту NPC, потому что DialogueManager умеет подключаться только
## к узлам с сигналом `interacted` в группе "npc": та же группа, тот же сигнал,
## тот же `get_dialogue_id()`. Внешне это не человек, а ящик на козлах.
##
## Почему так: в исходной сборке у стадии «Осмотри вторую точку на стройке» был
## только маркер цели, а запускать диалог `twin_box` было нечему — сюжет вставал
## на втором акте. Этот узел и есть тот самый «второй ящик».
##
## Публичный API:
##   interact(player) -> void          (вызывает E игрока через Interactor)
##   get_dialogue_id() -> String
##   get_interact_hint() -> String
##   is_opened() -> bool
## Сигналы: interacted(npc, player), opened()

signal interacted(npc: Node, player: Node)
signal opened()

@export var npc_id: String = "twin_box"
@export var display_name: String = "Коробка"
@export var dialogue_id: String = "twin_box"
@export var interact_hint: String = "E — осмотреть коробку"
## После находки ящик остаётся на месте (он вскрыт), но больше не реагирует на E.
@export var disable_after_opened: bool = true

var _opened: bool = false


func _ready() -> void:
	add_to_group("npc")
	add_to_group("interactable")
	set_meta("interactable", true)
	set_meta("npc_id", npc_id)
	set_meta("dialogue_id", dialogue_id)
	set_meta("interact_hint", interact_hint)

	var quest := get_node_or_null("/root/QuestState")
	if quest != null and quest.has_signal("flag_changed"):
		quest.flag_changed.connect(_on_flag_changed)
		_sync_from_quest(quest)


func interact(player: Node3D = null) -> void:
	if _opened and disable_after_opened:
		return
	interacted.emit(self, player)


func get_dialogue_id() -> String:
	return dialogue_id


func get_interact_hint() -> String:
	if _opened:
		return "Коробка уже вскрыта"
	return interact_hint


func is_opened() -> bool:
	return _opened


func _on_flag_changed(flag: String, value: Variant) -> void:
	if flag == "twin_box_found" and bool(value):
		_apply_opened()


func _sync_from_quest(quest: Node) -> void:
	if quest.has_method("has_flag") and bool(quest.call("has_flag", "twin_box_found")):
		_apply_opened()


func _apply_opened() -> void:
	if _opened:
		return
	_opened = true
	if disable_after_opened:
		set_meta("interactable", false)
	opened.emit()
