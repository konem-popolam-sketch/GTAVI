extends Node
## DialogueAudio — озвучка реплик и приглушение музыки на время диалога.
##
## Слушает автолоад DialogueManager:
##   dialogue_started(dialogue_id, npc)        → музыка тише на duck_music_db
##   line_changed(dialogue_id, node_id, …)     → AudioManager.play_voice(...)
##   dialogue_ended(dialogue_id, ending_id)    → стоп озвучки, музыка обратно
##
## Озвучка необязательна: если файла нет (или манифеста нет), play_voice вернёт
## false — диалог идёт дальше с субтитрами, мы только пишем строку в лог.
##
## Управление игроком, пауза и интерактор этому узлу не принадлежат: он трогает
## исключительно шину Music и проигрыватель озвучки.

@export var enabled: bool = true
## Приглушение музыки на диалог, дБ (0 — не трогать музыку).
@export var duck_music_db: float = -6.0
## Писать в лог пропущенную озвучку (по одному разу на реплику).
@export var log_missing_voice: bool = true

var _audio: Variant = null
var _manager: Variant = null
var _ducked: bool = false
var _missing: Dictionary = {}


func _ready() -> void:
	_audio = get_node_or_null("/root/AudioManager")
	if _audio == null:
		push_warning("[dialogue_audio] нет автолоада AudioManager — озвучка выключена")
		return
	_manager = get_node_or_null("/root/DialogueManager")
	if _manager == null:
		push_warning("[dialogue_audio] нет автолоада DialogueManager — нечего озвучивать")
		return
	if not _manager.has_signal("dialogue_started"):
		push_warning("[dialogue_audio] у DialogueManager нет сигнала dialogue_started")
		return
	_manager.connect("dialogue_started", _on_dialogue_started)
	_manager.connect("line_changed", _on_line_changed)
	_manager.connect("dialogue_ended", _on_dialogue_ended)


# --- Публичный API -----------------------------------------------------------


## Проиграть озвучку текущей реплики вручную (например, кнопкой «повтор»).
func replay_current_line() -> bool:
	if _manager == null or _audio == null:
		return false
	if not _manager.has_method("is_active"):
		return false
	if not bool(_manager.is_active()):
		return false
	return bool(_audio.play_voice(
		str(_manager.get_dialogue_id()),
		str(_manager.get_current_node_id())
	))


func is_ducked() -> bool:
	return _ducked


# --- Сигналы DialogueManager -------------------------------------------------


func _on_dialogue_started(_dialogue_id: String, _npc: Node) -> void:
	if not enabled:
		return
	_set_duck(true)


func _on_line_changed(
	dialogue_id: String,
	node_id: String,
	_speaker: String,
	_text: String,
	_choices: Array
) -> void:
	if not enabled or _audio == null:
		return
	var played := bool(_audio.play_voice(dialogue_id, node_id))
	if played:
		return
	if not log_missing_voice:
		return
	var key := "%s_%s" % [dialogue_id, node_id]
	if _missing.has(key):
		return
	_missing[key] = true
	print("[dialogue_audio] озвучки нет (тихий режим): %s" % key)


func _on_dialogue_ended(_dialogue_id: String, _ending_id: int) -> void:
	if _audio != null:
		_audio.stop_voice()
	if not enabled:
		return
	_set_duck(false)


# --- Внутреннее --------------------------------------------------------------


func _set_duck(value: bool) -> void:
	if _ducked == value:
		return
	_ducked = value
	if _audio == null or not _audio.has_method("set_music_duck"):
		return
	_audio.set_music_duck(duck_music_db if value else 0.0)
