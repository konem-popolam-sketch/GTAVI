extends Control
## PauseMenu — пауза «Ночной смены»: продолжить, громкость Master/Music/SFX/Voice,
## чувствительность мыши, полный экран, размер шрифта диалога, контраст подсказок,
## выход в главное меню/игру.
##
## Открытие: Esc в игре. Если открыт диалог — Esc закрывает диалог (это делает
## DialogueManager), меню не появляется. На титульной плашке пауза тоже не
## открывается: нажатие съедает сама плашка.
##
## Пауза ставит get_tree().paused = true; сам узел живёт в PROCESS_MODE_ALWAYS,
## поэтому кнопки и слайдеры работают на паузе. Настройки — user://settings.cfg
## (через UiSettings), громкость дополнительно уходит в AudioManager.
##
## Публичный API:
##   open_menu(); close_menu(); toggle_menu(); is_open()
##   open()/close() — алиасы для интегратора.
## Сигналы: pause_opened(), pause_closed().

const UiSettings = preload("res://scripts/ui/ui_settings.gd")

signal pause_opened()
signal pause_closed()

const HUD_GROUP := "hud"
const DIALOGUE_UI_GROUP := "dialogue_ui"
const BUS_ROWS := [
	{"bus": "Master", "label": "Общая громкость"},
	{"bus": "Music", "label": "Музыка"},
	{"bus": "SFX", "label": "Эффекты"},
	{"bus": "Voice", "label": "Голоса"},
]

@onready var continue_button: Button = $Dim/Center/Panel/Margin/VBox/ContinueButton
@onready var menu_button: Button = $Dim/Center/Panel/Margin/VBox/ButtonsRow/MenuButton
@onready var quit_button: Button = $Dim/Center/Panel/Margin/VBox/ButtonsRow/QuitButton

@onready var master_slider: HSlider = $Dim/Center/Panel/Margin/VBox/MasterRow/MasterSlider
@onready var master_value: Label = $Dim/Center/Panel/Margin/VBox/MasterRow/MasterValue
@onready var music_slider: HSlider = $Dim/Center/Panel/Margin/VBox/MusicRow/MusicSlider
@onready var music_value: Label = $Dim/Center/Panel/Margin/VBox/MusicRow/MusicValue
@onready var sfx_slider: HSlider = $Dim/Center/Panel/Margin/VBox/SfxRow/SfxSlider
@onready var sfx_value: Label = $Dim/Center/Panel/Margin/VBox/SfxRow/SfxValue
@onready var voice_slider: HSlider = $Dim/Center/Panel/Margin/VBox/VoiceRow/VoiceSlider
@onready var voice_value: Label = $Dim/Center/Panel/Margin/VBox/VoiceRow/VoiceValue

@onready var sensitivity_slider: HSlider = $Dim/Center/Panel/Margin/VBox/SensitivityRow/SensitivitySlider
@onready var sensitivity_value: Label = $Dim/Center/Panel/Margin/VBox/SensitivityRow/SensitivityValue
@onready var fullscreen_check: CheckButton = $Dim/Center/Panel/Margin/VBox/FullscreenRow/FullscreenCheck
@onready var font_option: OptionButton = $Dim/Center/Panel/Margin/VBox/FontRow/FontOption
@onready var contrast_check: CheckButton = $Dim/Center/Panel/Margin/VBox/ContrastRow/ContrastCheck
@onready var hints_check: CheckButton = $Dim/Center/Panel/Margin/VBox/HintsRow/HintsCheck

var _sliders: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	UiSettings.ensure_loaded()
	_sliders = {
		"Master": {"slider": master_slider, "value": master_value},
		"Music": {"slider": music_slider, "value": music_value},
		"SFX": {"slider": sfx_slider, "value": sfx_value},
		"Voice": {"slider": voice_slider, "value": voice_value},
	}
	_setup_volume_rows()
	_setup_sensitivity_row()
	_setup_option_rows()
	continue_button.pressed.connect(close_menu)
	menu_button.pressed.connect(_on_menu_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	_sync_from_settings()


# --- Публичный API -----------------------------------------------------------


func is_open() -> bool:
	return visible


func open_menu() -> void:
	if visible:
		return
	_sync_from_settings()
	visible = true
	get_tree().paused = true
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_set_hud_paused(true)
	continue_button.grab_focus()
	pause_opened.emit()
	print("[pause] пауза открыта")


func close_menu() -> void:
	if not visible:
		return
	UiSettings.save_settings()
	visible = false
	get_tree().paused = false
	_set_hud_paused(false)
	var player := get_tree().get_first_node_in_group("player")
	if player != null and player.has_method("set_mouse_captured"):
		if DisplayServer.get_name() != "headless":
			player.call("set_mouse_captured", true)
	pause_closed.emit()
	print("[pause] пауза закрыта")


func toggle_menu() -> void:
	if visible:
		close_menu()
	else:
		open_menu()


# Алиасы на случай, если интегратор ждёт короткие имена.
func open() -> void:
	open_menu()


func close() -> void:
	close_menu()


# --- Ввод --------------------------------------------------------------------


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("pause"):
		return
	if visible:
		close_menu()
		get_viewport().set_input_as_handled()
		return
	if _pause_blocked():
		return
	open_menu()
	get_viewport().set_input_as_handled()


## Esc занят диалогом или титульной плашкой — пауза не вмешивается.
func _pause_blocked() -> bool:
	var manager := get_node_or_null("/root/DialogueManager")
	if manager != null and manager.has_method("is_active"):
		if bool(manager.call("is_active")):
			return true
	return _title_open()


func _title_open() -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var card := scene.find_child("TitleCard", true, false)
	if card != null and card.has_method("is_open"):
		return bool(card.call("is_open"))
	return false


# --- Настройки: громкость ----------------------------------------------------


func _setup_volume_rows() -> void:
	for entry in BUS_ROWS:
		var row: Dictionary = entry
		var bus := str(row["bus"])
		var slider: HSlider = _sliders[bus]["slider"]
		var value_label: Label = _sliders[bus]["value"]
		slider.min_value = 0.0
		slider.max_value = 100.0
		slider.step = 1.0
		slider.value = roundf(UiSettings.get_effective_volume(bus) * 100.0)
		slider.value_changed.connect(_on_volume_changed.bind(bus, value_label))
		_refresh_volume_label(bus, value_label)


func _on_volume_changed(value: float, bus: String, value_label: Label) -> void:
	UiSettings.set_volume(bus, value / 100.0)
	_refresh_volume_label(bus, value_label)


func _refresh_volume_label(bus: String, value_label: Label) -> void:
	if value_label == null:
		return
	value_label.text = "%d%%" % int(roundf(UiSettings.get_effective_volume(bus) * 100.0))


# --- Настройки: мышь, экран, доступность --------------------------------------


func _setup_sensitivity_row() -> void:
	sensitivity_slider.min_value = UiSettings.SENS_MULT_MIN
	sensitivity_slider.max_value = UiSettings.SENS_MULT_MAX
	sensitivity_slider.step = 0.05
	sensitivity_slider.value = UiSettings.get_mouse_multiplier()
	sensitivity_slider.value_changed.connect(_on_sensitivity_changed)
	_refresh_sensitivity_label()


func _on_sensitivity_changed(value: float) -> void:
	UiSettings.set_mouse_multiplier(value)
	_refresh_sensitivity_label()


func _refresh_sensitivity_label() -> void:
	sensitivity_slider.set_value_no_signal(UiSettings.get_mouse_multiplier())
	sensitivity_value.text = "%.2f×" % UiSettings.get_mouse_multiplier()


func _setup_option_rows() -> void:
	fullscreen_check.button_pressed = UiSettings.fullscreen
	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	font_option.clear()
	for step_name in UiSettings.FONT_STEP_NAMES:
		font_option.add_item(str(step_name))
	font_option.selected = UiSettings.get_dialogue_font_step()
	font_option.item_selected.connect(_on_font_selected)
	contrast_check.button_pressed = UiSettings.high_contrast
	contrast_check.toggled.connect(_on_contrast_toggled)
	hints_check.button_pressed = UiSettings.hints_visible
	hints_check.toggled.connect(_on_hints_toggled)


func _on_fullscreen_toggled(pressed: bool) -> void:
	UiSettings.fullscreen = pressed
	UiSettings.apply_fullscreen()
	UiSettings.save_settings()


func _on_font_selected(index: int) -> void:
	UiSettings.set_dialogue_font_step(index)
	_apply_ui_live()


func _on_contrast_toggled(pressed: bool) -> void:
	UiSettings.set_high_contrast(pressed)
	_apply_ui_live()


func _on_hints_toggled(pressed: bool) -> void:
	UiSettings.set_hints_visible(pressed)
	_apply_ui_live()


## Перечитать значения настроек в виджеты (без выстреливания сигналов).
func _sync_from_settings() -> void:
	for bus in _sliders.keys():
		var slider: HSlider = _sliders[bus]["slider"]
		var value_label: Label = _sliders[bus]["value"]
		slider.set_value_no_signal(roundf(UiSettings.get_effective_volume(str(bus)) * 100.0))
		_refresh_volume_label(str(bus), value_label)
	sensitivity_slider.set_value_no_signal(UiSettings.get_mouse_multiplier())
	_refresh_sensitivity_label()
	fullscreen_check.set_pressed_no_signal(UiSettings.fullscreen)
	font_option.selected = UiSettings.get_dialogue_font_step()
	contrast_check.set_pressed_no_signal(UiSettings.high_contrast)
	hints_check.set_pressed_no_signal(UiSettings.hints_visible)


## Применить доступность к уже открытым HUD и диалогу.
func _apply_ui_live() -> void:
	var hud := get_tree().get_first_node_in_group(HUD_GROUP)
	if hud != null and hud.has_method("apply_settings"):
		hud.call("apply_settings")
	var dialogue := get_tree().get_first_node_in_group(DIALOGUE_UI_GROUP)
	if dialogue != null and dialogue.has_method("apply_settings"):
		dialogue.call("apply_settings")


func _set_hud_paused(value: bool) -> void:
	var hud := get_tree().get_first_node_in_group(HUD_GROUP)
	if hud == null:
		return
	if hud.has_method("set_paused"):
		hud.call("set_paused", value)
	elif hud is CanvasItem:
		(hud as CanvasItem).visible = not value


# --- Кнопки ------------------------------------------------------------------


func _on_menu_pressed() -> void:
	UiSettings.save_settings()
	close_menu()
	call_deferred("_reload_scene")


func _reload_scene() -> void:
	# Главного меню в проекте нет: «в меню» = перезапуск сцены с титульной плашкой.
	var error := get_tree().reload_current_scene()
	if error != OK:
		push_warning("[pause] не удалось перезапустить сцену (код %d)" % error)


func _on_quit_pressed() -> void:
	UiSettings.save_settings()
	get_tree().quit()
