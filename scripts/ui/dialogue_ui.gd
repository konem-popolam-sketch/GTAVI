extends Control
## DialogueUI v2 — субтитры диалога: имя, реплика с плавным появлением
## (typewriter), варианты ответа 1–3, подсказка Esc.
##
## Подключается к DialogueManager сам, интегратору достаточно добавить
## ui/dialogue.tscn под CanvasLayer. Ввод (E, 1–3, Esc) обрабатывает автолоад,
## а этот скрипт только «досрочно дорисовывает» реплику: пробел или E во время
## печати показывают текст целиком и НЕ перескакивают на следующую реплику.
##
## Синхронизация с озвучкой: пока AudioManager.is_voice_playing(), E/пробел
## не перелистывают реплику (текст не обрывается). Страховка — не дольше
## VOICE_HOLD_MAX секунд, чтобы зависший звук не запер диалог. Если
## /root/AudioManager нет — всё работает как раньше.
##
## Доступность: размер шрифта берётся из UiSettings (3 ступени, меняется в паузе),
## высокий контраст — тоже оттуда.
##
## Публичный API: refresh(), apply_settings(), is_typing(), complete_line().

const UiSettings = preload("res://scripts/ui/ui_settings.gd")

const SPEAKER_COLORS := {
	"mila": Color(0.4, 0.92, 1.0),
	"kostya": Color(1.0, 0.82, 0.45),
	"foreman": Color(1.0, 0.6, 0.35),
	"voice": Color(0.95, 0.45, 0.85),
	"galya": Color(0.6, 1.0, 0.7),
	"timur": Color(0.75, 0.8, 1.0),
}
## Скорость появления текста, символов в секунду (по брифу 45–60).
const TYPING_CHARS_PER_SECOND := 55.0
## Сколько максимум ждём конца озвучки, прежде чем разрешить листать дальше.
const VOICE_HOLD_MAX := 30.0

@onready var speaker_label: Label = $Panel/Margin/VBox/SpeakerRow/SpeakerLabel
@onready var progress_label: Label = $Panel/Margin/VBox/SpeakerRow/ProgressLabel
@onready var line_label: Label = $Panel/Margin/VBox/LineLabel
@onready var choices_box: VBoxContainer = $Panel/Margin/VBox/ChoicesBox
@onready var continue_label: Label = $Panel/Margin/VBox/ContinueLabel

var _manager = null
var _typing: bool = false
var _typed_chars: float = 0.0
var _full_text: String = ""
var _has_choices: bool = false
var _voice_wait_since: int = -1


func _ready() -> void:
	add_to_group("dialogue_ui")
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide()
	UiSettings.ensure_loaded()
	_manager = get_node_or_null("/root/DialogueManager")
	if _manager != null:
		if _manager.has_signal("dialogue_started"):
			_manager.connect("dialogue_started", Callable(self, "_on_dialogue_started"))
		if _manager.has_signal("line_changed"):
			_manager.connect("line_changed", Callable(self, "_on_line_changed"))
		if _manager.has_signal("dialogue_ended"):
			_manager.connect("dialogue_ended", Callable(self, "_on_dialogue_ended"))
	else:
		push_warning("[dialogue_ui] нет автолоада DialogueManager — субтитры не покажутся")
	_clear_choices()
	_apply_accessibility()
	set_process(true)


func _process(delta: float) -> void:
	if not _typing:
		return
	_typed_chars += TYPING_CHARS_PER_SECOND * delta
	if _typed_chars >= float(_full_text.length()):
		complete_line()
		return
	line_label.visible_characters = int(_typed_chars)


# --- Публичный API ----------------------------------------------------------


## Перерисовать текущую реплику из состояния менеджера.
func refresh() -> void:
	if not _manager_active():
		hide()
		return
	show()
	_render_line(
		str(_manager.get_dialogue_id()),
		str(_manager.get_current_speaker()),
		str(_manager.get_current_text()),
		_manager.get_choices()
	)


## Показать реплику целиком, не перескакивая на следующую.
func complete_line() -> void:
	if not _typing and line_label.visible_characters < 0:
		return
	_typing = false
	_typed_chars = float(_full_text.length())
	line_label.visible_characters = -1
	_voice_wait_since = -1
	_reveal_choices()
	_update_continue_hint()


func is_typing() -> bool:
	return _typing


## Перечитать доступность (шрифт/контраст) — вызывает пауза.
func apply_settings() -> void:
	_apply_accessibility()
	for child in choices_box.get_children():
		if child is Label:
			var label := child as Label
			label.add_theme_font_size_override("font_size", _choice_font_size())
			_apply_choice_colors(label)


# --- Ввод: пробел/E дорисовывают реплику, озвучка держит её -----------------


func _input(event: InputEvent) -> void:
	if not _manager_active() or not visible:
		return
	var next_pressed := event.is_action_pressed("interact") or _is_space_pressed(event)
	if not next_pressed:
		return
	if _typing:
		# Дорантаймить до конца и съесть нажатие, чтобы менеджер не ушёл вперёд.
		complete_line()
		get_viewport().set_input_as_handled()
		return
	if _voice_playing() and not _voice_hold_expired():
		# Реплика озвучивается: держим её, не обрываем звук.
		get_viewport().set_input_as_handled()


func _is_space_pressed(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return false
	return key_event.physical_keycode == KEY_SPACE or key_event.keycode == KEY_SPACE


# --- Сигналы DialogueManager ------------------------------------------------


func _on_dialogue_started(dialogue_id: String, _npc: Node) -> void:
	_clear_choices()
	_has_choices = false
	speaker_label.text = ""
	line_label.text = ""
	line_label.visible_characters = -1
	_typing = false
	_full_text = ""
	_apply_speaker_color(dialogue_id, str(_manager.get_current_speaker()))
	show()


func _on_line_changed(
	dialogue_id: String,
	_node_id: String,
	speaker: String,
	text: String,
	choices: Array
) -> void:
	show()
	_render_line(dialogue_id, speaker, text, choices)


func _on_dialogue_ended(_dialogue_id: String, _ending_id: int) -> void:
	_clear_choices()
	_has_choices = false
	_typing = false
	_full_text = ""
	line_label.text = ""
	line_label.visible_characters = -1
	speaker_label.text = ""
	hide()


# --- Отрисовка ---------------------------------------------------------------


func _render_line(dialogue_id: String, speaker: String, text: String, choices: Array) -> void:
	_apply_accessibility()
	speaker_label.text = speaker
	_apply_speaker_color(dialogue_id, speaker)
	progress_label.text = str(_manager.get_progress_text())
	_has_choices = not choices.is_empty()
	_render_choices(choices)
	_start_typing(text)
	_update_continue_hint()


func _start_typing(text: String) -> void:
	_full_text = text if text != null else ""
	line_label.text = _full_text
	_typed_chars = 0.0
	_voice_wait_since = -1
	if _full_text.is_empty():
		# Пустой текст не должен ни крутить таймер, ни падать.
		_typing = false
		line_label.visible_characters = -1
		_reveal_choices()
		return
	_typing = true
	line_label.visible_characters = 0
	choices_box.visible = false


func _reveal_choices() -> void:
	choices_box.visible = _has_choices


func _update_continue_hint() -> void:
	if _typing:
		continue_label.text = "пробел / E — показать всё · Esc — выйти"
	elif _has_choices:
		continue_label.text = "1–3 — выбрать ответ · Esc — выйти"
	elif _manager_has_next_line():
		continue_label.text = "E — дальше · Esc — выйти"
	else:
		continue_label.text = "E — закрыть · Esc — выйти"


func _render_choices(choices: Array) -> void:
	_clear_choices()
	for index in choices.size():
		var choice_variant: Variant = choices[index]
		if typeof(choice_variant) != TYPE_DICTIONARY:
			continue
		var choice_text := str((choice_variant as Dictionary).get("text", ""))
		var label := Label.new()
		label.name = "Choice%d" % (index + 1)
		label.text = "%d. %s" % [index + 1, choice_text]
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override("font_size", _choice_font_size())
		_apply_choice_colors(label)
		choices_box.add_child(label)
	choices_box.visible = false


func _clear_choices() -> void:
	for child in choices_box.get_children():
		choices_box.remove_child(child)
		child.queue_free()


func _apply_speaker_color(dialogue_id: String, speaker: String) -> void:
	var color: Color = SPEAKER_COLORS.get(dialogue_id, Color(0.4, 0.92, 1.0))
	speaker_label.add_theme_color_override("font_color", color)
	speaker_label.text = speaker


# --- Доступность -------------------------------------------------------------


func _choice_font_size() -> int:
	return maxi(UiSettings.get_dialogue_font_size() - 1, 12)


func _apply_accessibility() -> void:
	var font_size := UiSettings.get_dialogue_font_size()
	line_label.add_theme_font_size_override("font_size", font_size)
	speaker_label.add_theme_font_size_override("font_size", font_size + 4)
	progress_label.add_theme_font_size_override("font_size", maxi(font_size - 6, 11))
	continue_label.add_theme_font_size_override("font_size", maxi(font_size - 6, 11))
	if UiSettings.high_contrast:
		line_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
		continue_label.add_theme_color_override("font_color", Color(0.86, 0.93, 1.0, 1))
		continue_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		continue_label.add_theme_constant_override("outline_size", 5)
	else:
		line_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1, 1))
		continue_label.add_theme_color_override("font_color", Color(0.55, 0.64, 0.72, 1))
		continue_label.add_theme_constant_override("outline_size", 0)


func _apply_choice_colors(label: Label) -> void:
	if UiSettings.high_contrast:
		label.add_theme_color_override("font_color", Color(0.95, 1.0, 1.0, 1.0))
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		label.add_theme_constant_override("outline_size", 4)
	else:
		label.add_theme_color_override("font_color", Color(0.8, 0.94, 1.0, 1.0))


# --- Синхронизация с озвучкой и менеджером ---------------------------------


func _manager_active() -> bool:
	if _manager == null or not _manager.has_method("is_active"):
		return false
	return bool(_manager.call("is_active"))


func _manager_has_next_line() -> bool:
	if _manager == null or not _manager.has_method("has_next_line"):
		return false
	return bool(_manager.call("has_next_line"))


func _voice_playing() -> bool:
	var audio := get_node_or_null("/root/AudioManager")
	if audio == null or not audio.has_method("is_voice_playing"):
		return false
	return bool(audio.call("is_voice_playing"))


func _voice_hold_expired() -> bool:
	if _voice_wait_since < 0:
		_voice_wait_since = Time.get_ticks_msec()
		return false
	return float(Time.get_ticks_msec() - _voice_wait_since) / 1000.0 > VOICE_HOLD_MAX
