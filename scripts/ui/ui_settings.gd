extends RefCounted
## UiSettings — настройки интерфейса и громкости «Ночной смены».
##
## Один статический класс на весь запуск: его читают HUD, DialogueUI и
## PauseMenu, поэтому настройка, изменённая в паузе, сразу видна остальным.
## Автолоад не нужен — скрипт подключается через
##   const UiSettings = preload("res://scripts/ui/ui_settings.gd")
##
## Файл: user://settings.cfg
##   [audio] master/music/sfx/voice — линейная громкость 0…1
##           muted_<шина>          — осознанный мьют шины (t47), иначе ноль лечится
##   [input] mouse_sensitivity     — сырая чувствительность мыши (как у Player)
##   [video] fullscreen            — полный экран
##   [ui]    dialogue_font_step    — 0/1/2 (мелкий/обычный/крупный)
##           hints_visible         — подсказки «E — …» на HUD (M)
##           high_contrast         — высокий контраст подсказок
##
## Публичный API:
##   ensure_loaded(); reload_settings(); load_settings(); save_settings()
##   get_volume(bus) / set_volume(bus, linear, persist = true)
##   get_mouse_multiplier() / set_mouse_multiplier(mult)
##   get_dialogue_font_size() / get_dialogue_font_step() / set_dialogue_font_step(step)
##   apply_audio(); apply_mouse_sensitivity(); apply_fullscreen(); apply_all()

const CONFIG_PATH := "user://settings.cfg"
const CONFIG_VERSION := 1
## Конфиг AudioManager (только чтение): из него берём громкости, если
## settings.cfg ещё нет, а AudioManager почему-то вернул 0.
const AUDIO_CONFIG_PATH := "user://audio.cfg"
## Меньше этого линейная громкость считается «мёртвым нулём».
const SILENCE_EPSILON := 0.001

const BUSES := ["Master", "Music", "SFX", "Voice"]
## Значения по умолчанию (линейные) совпадают с docs/PHASE2.md:
## Master 0 dB, Music −12 dB, SFX −8 dB, Voice −4 dB.
const DEFAULT_VOLUME := {
	"Master": 1.0,
	"Music": 0.251188643,
	"SFX": 0.398107171,
	"Voice": 0.630957344,
}

## Три ступени размера шрифта диалога (доступность).
const FONT_STEPS := [18, 21, 25]
const FONT_STEP_NAMES := ["мелкий", "обычный", "крупный"]
const DEFAULT_FONT_STEP := 1

const SENS_DEFAULT := 0.0028
const SENS_MIN := 0.0005
const SENS_MAX := 0.0100
const SENS_MULT_MIN := 0.3
const SENS_MULT_MAX := 3.0

## Откуда взялась громкость шины: "settings" (пользователь сохранил ранее),
## "audio" (подхватили из AudioManager/audio.cfg), "default" (значение по
## умолчанию), "user" (ползунок в паузе в этом запуске). Нужно, чтобы отличать
## осознанный ноль (пользователь замьютил) от «мёртвого» нуля при загрузке.
const SOURCE_SETTINGS := "settings"
const SOURCE_AUDIO := "audio"
const SOURCE_DEFAULT := "default"
const SOURCE_USER := "user"

## Отметка осознанного мьюта шины в settings.cfg: `[audio] muted_master=true`.
## Нужна, чтобы отличить «пользователь выкрутил в 0» от нуля, записанного
## старым багом t47; такой ноль без отметки лечится заводским значением.
const MUTE_PREFIX := "muted_"

static var _loaded: bool = false
static var _volume_source: Dictionary = {}
static var _muted: Dictionary = {}

static var volumes: Dictionary = {
	"Master": 1.0,
	"Music": 0.251188643,
	"SFX": 0.398107171,
	"Voice": 0.630957344,
}
static var mouse_sensitivity: float = SENS_DEFAULT
static var fullscreen: bool = false
static var dialogue_font_step: int = DEFAULT_FONT_STEP
static var hints_visible: bool = true
static var high_contrast: bool = true


# --- Загрузка / сохранение ---------------------------------------------------


static func ensure_loaded() -> void:
	if _loaded:
		return
	load_settings()


## Перечитать файл с диска (смоук-тест проверяет настройки после сохранения).
static func reload_settings() -> void:
	_loaded = false
	load_settings()


static func load_settings() -> void:
	_loaded = true
	volumes = DEFAULT_VOLUME.duplicate(true)
	_volume_source.clear()
	_muted.clear()
	for bus in BUSES:
		_volume_source[str(bus)] = SOURCE_DEFAULT
		_muted[str(bus)] = false
	mouse_sensitivity = SENS_DEFAULT
	fullscreen = false
	dialogue_font_step = DEFAULT_FONT_STEP
	hints_visible = true
	high_contrast = true

	var config := ConfigFile.new()
	var loaded := config.load(CONFIG_PATH) == OK
	if loaded:
		for bus in BUSES:
			var key := str(bus).to_lower()
			var fallback := float(DEFAULT_VOLUME[bus])
			# settings.cfg — явный выбор пользователя. Ноль уважаем только если
			# он помечен как осознанный мьют (muted_<шина>); «сиротский» ноль от
			# старого бага t47 лечим заводским значением (t47).
			var value := clampf(float(config.get_value("audio", key, fallback)), 0.0, 1.0)
			var muted := bool(config.get_value("audio", MUTE_PREFIX + key, false))
			if value <= SILENCE_EPSILON and not muted:
				push_warning(
					"[ui_settings] settings.cfg: %s=0 без отметки мьюта — лечу заводским %.3f"
					% [bus, fallback]
				)
				value = fallback
				_volume_source[bus] = SOURCE_DEFAULT
			else:
				_volume_source[bus] = SOURCE_SETTINGS
			volumes[bus] = value
			_muted[bus] = muted and value <= SILENCE_EPSILON
		mouse_sensitivity = clampf(
			float(config.get_value("input", "mouse_sensitivity", SENS_DEFAULT)),
			SENS_MIN, SENS_MAX
		)
		fullscreen = bool(config.get_value("video", "fullscreen", false))
		dialogue_font_step = clampi(
			int(config.get_value("ui", "dialogue_font_step", DEFAULT_FONT_STEP)),
			0, FONT_STEPS.size() - 1
		)
		hints_visible = bool(config.get_value("ui", "hints_visible", true))
		high_contrast = bool(config.get_value("ui", "high_contrast", true))
	else:
		# settings.cfg ещё нет. Берём громкости из AudioManager только если он
		# уже готов и значение правдоподобное; «мёртвый» 0.0 (менеджер не успел
		# применить конфиг / audio.cfg испорчен) не наследуем — иначе тишина
		# уезжает в settings.cfg при первом же закрытии паузы (t47).
		for bus in BUSES:
			var bus_name := str(bus)
			var value := _audio_manager_volume(bus_name)
			if value < 0.0:
				value = _audio_config_volume(bus_name)
			if value < 0.0:
				value = float(DEFAULT_VOLUME[bus_name])
				_volume_source[bus_name] = SOURCE_DEFAULT
			else:
				_volume_source[bus_name] = SOURCE_AUDIO
			volumes[bus_name] = value

	apply_all()


static func save_settings() -> void:
	var config := ConfigFile.new()
	for bus in BUSES:
		var key := str(bus).to_lower()
		# «Мёртвый» ноль (не выбор пользователя) в файл не пишем: иначе игра
		# остаётся беззвучной навсегда (t47).
		config.set_value("audio", key, _effective_volume(str(bus)))
		config.set_value("audio", MUTE_PREFIX + key, bool(_muted.get(str(bus), false)))
	config.set_value("input", "mouse_sensitivity", mouse_sensitivity)
	config.set_value("video", "fullscreen", fullscreen)
	config.set_value("ui", "dialogue_font_step", dialogue_font_step)
	config.set_value("ui", "hints_visible", hints_visible)
	config.set_value("ui", "high_contrast", high_contrast)
	config.set_value("meta", "version", CONFIG_VERSION)
	var error := config.save(CONFIG_PATH)
	if error != OK:
		push_warning("[ui_settings] не удалось сохранить %s (код %d)" % [CONFIG_PATH, error])


static func reset_defaults() -> void:
	volumes = DEFAULT_VOLUME.duplicate(true)
	for bus in BUSES:
		_volume_source[str(bus)] = SOURCE_DEFAULT
		_muted[str(bus)] = false
	mouse_sensitivity = SENS_DEFAULT
	fullscreen = false
	dialogue_font_step = DEFAULT_FONT_STEP
	hints_visible = true
	high_contrast = true
	apply_all()
	save_settings()


# --- Громкость ---------------------------------------------------------------


static func get_volume(bus_name: String) -> float:
	return float(volumes.get(bus_name, DEFAULT_VOLUME.get(bus_name, 1.0)))


static func set_volume(bus_name: String, linear: float, persist: bool = true) -> void:
	if not volumes.has(bus_name):
		volumes[bus_name] = float(DEFAULT_VOLUME.get(bus_name, 1.0))
	volumes[bus_name] = clampf(linear, 0.0, 1.0)
	# Это осознанное действие (ползунок): ноль сохраняем как есть и помечаем
	# мьютом, чтобы он не лечился как «мёртвый».
	_volume_source[bus_name] = SOURCE_USER
	_muted[bus_name] = volumes[bus_name] <= SILENCE_EPSILON
	_apply_bus(bus_name)
	if persist:
		save_settings()


## Громкость с защитой от «мёртвого нуля»: если ноль пришёл не от пользователя
## и не из settings.cfg (а из AudioManager/audio.cfg/дефолта), возвращаем
## заводское значение и лечим состояние.
static func get_effective_volume(bus_name: String) -> float:
	return _effective_volume(bus_name)


# --- Чувствительность мыши ---------------------------------------------------


static func get_mouse_multiplier() -> float:
	return clampf(mouse_sensitivity / SENS_DEFAULT, SENS_MULT_MIN, SENS_MULT_MAX)


static func set_mouse_multiplier(mult: float) -> void:
	mouse_sensitivity = clampf(SENS_DEFAULT * mult, SENS_MIN, SENS_MAX)
	apply_mouse_sensitivity()
	save_settings()


# --- Шрифт диалога и подсказки ----------------------------------------------


static func get_dialogue_font_step() -> int:
	return clampi(dialogue_font_step, 0, FONT_STEPS.size() - 1)


static func get_dialogue_font_size() -> int:
	return int(FONT_STEPS[get_dialogue_font_step()])


static func get_dialogue_font_step_name() -> String:
	return str(FONT_STEP_NAMES[get_dialogue_font_step()])


static func set_dialogue_font_step(step: int, persist: bool = true) -> void:
	dialogue_font_step = clampi(step, 0, FONT_STEPS.size() - 1)
	if persist:
		save_settings()


static func set_hints_visible(value: bool, persist: bool = true) -> void:
	hints_visible = value
	if persist:
		save_settings()


static func set_high_contrast(value: bool, persist: bool = true) -> void:
	high_contrast = value
	if persist:
		save_settings()


# --- Применение настроек -----------------------------------------------------


static func apply_all() -> void:
	apply_audio()
	apply_mouse_sensitivity()
	apply_fullscreen()


static func apply_audio() -> void:
	var audio := _audio()
	if audio == null:
		return
	for bus in BUSES:
		_apply_bus(str(bus))


static func apply_mouse_sensitivity() -> void:
	var player := _player()
	if player == null:
		return
	# Player.mouse_sensitivity — обычный @export; пишем напрямую (сеттера нет).
	if "mouse_sensitivity" in player:
		player.set("mouse_sensitivity", mouse_sensitivity)


static func apply_fullscreen() -> void:
	if DisplayServer.get_name() == "headless":
		return
	# Полный экран без окна не переключаем: в headless это шумит в логах.
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen
		else DisplayServer.WINDOW_MODE_WINDOWED
	)


# --- Внутреннее --------------------------------------------------------------


static func _apply_bus(bus_name: String) -> void:
	var audio := _audio()
	if audio == null:
		return
	audio.set_bus_volume(bus_name, _effective_volume(bus_name))


## Громкость с защитой от «мёртвого нуля»: если ноль пришёл не от пользователя
## и не из settings.cfg (а из AudioManager/audio.cfg/дефолта), возвращаем
## заводское значение и лечим состояние.
static func _effective_volume(bus_name: String) -> float:
	var value := get_volume(bus_name)
	var source := str(_volume_source.get(bus_name, SOURCE_DEFAULT))
	var muted := bool(_muted.get(bus_name, false))
	if value <= SILENCE_EPSILON and not muted and source != SOURCE_USER:
		var fallback := float(DEFAULT_VOLUME.get(bus_name, 1.0))
		push_warning("[ui_settings] %s=0 без выбора пользователя — беру %.3f" % [
			bus_name, fallback
		])
		volumes[bus_name] = fallback
		_volume_source[bus_name] = SOURCE_DEFAULT
		return fallback
	return value


## Громкость из AudioManager; -1 — менеджер не готов или вернул «мёртвый» ноль.
## С t47 у AudioManager есть is_ready()/audio_ready; если их нет (старая сборка),
## обходимся is_node_ready().
static func _audio_manager_volume(bus_name: String) -> float:
	var audio := _audio()
	if audio == null:
		return -1.0
	if audio.has_method("is_ready"):
		if not bool(audio.call("is_ready")):
			return -1.0
	elif not audio.is_node_ready():
		return -1.0
	if not audio.has_method("get_bus_volume"):
		return -1.0
	var value := float(audio.call("get_bus_volume", bus_name))
	if value <= SILENCE_EPSILON:
		return -1.0
	return clampf(value, 0.0, 1.0)


## Значение из user://audio.cfg (если settings.cfg ещё нет); -1 — нет/ноль.
static func _audio_config_volume(bus_name: String) -> float:
	var config := ConfigFile.new()
	if config.load(AUDIO_CONFIG_PATH) != OK:
		return -1.0
	var value := float(config.get_value("bus", bus_name.to_lower(), -1.0))
	if value <= SILENCE_EPSILON:
		return -1.0
	return clampf(value, 0.0, 1.0)


static func _audio() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null("AudioManager")


static func _player() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.get_first_node_in_group("player")
