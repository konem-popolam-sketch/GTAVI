extends Node
## T47 SETTINGS SMOKE — регрессия «Master сохраняется как 0.0 после паузы».
##
## Запуск (изолированный профиль, иначе user:// недоступен на запись в песочнице):
##   $env:APPDATA = "<папка внутри workspace>"
##   tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . \
##       tests/settings_smoke.tscn --log-file tools\t47_settings_smoke.log
##
## Проверяет:
##   1) чистый user:// (нет settings.cfg и audio.cfg) → открыть и закрыть паузу:
##      Master = 1.0 в settings.cfg, в audio.cfg и в AudioManager;
##   2) settings.cfg с master=0.35 (выбор игрока) → после старта и закрытия
##      паузы остаётся 0.35 и в settings.cfg, и в audio.cfg;
##   3) старый «сиротский» ноль в settings.cfg (записан багом до t47) → лечится
##      заводским 1.0 и не уезжает обратно;
##   4) испорченный audio.cfg с нулями по всем шинам → значения лечатся
##      заводскими, а не уезжают нулём в settings.cfg;
##   5) явное действие пользователя (ползунок Master в 0) сохраняется как 0.0
##      с отметкой muted_master и переживает перезапуск — осознанный мьют цел.
##
## Успех — "T47 SETTINGS SMOKE OK" и код 0; провал — "T47 SETTINGS SMOKE FAIL: …".

const UiSettings = preload("res://scripts/ui/ui_settings.gd")
const PAUSE_SCENE := "res://ui/pause_menu.tscn"
const SETTINGS_PATH := "user://settings.cfg"
const AUDIO_PATH := "user://audio.cfg"

var _failures: Array[String] = []
var _menu: Control = null
var _audio: Node = null


func _ready() -> void:
	await _run()


func _run() -> void:
	print("[settings-smoke] старт T47")
	_audio = get_node_or_null("/root/AudioManager")
	if _audio == null:
		_failures.append("нет автолоада AudioManager")
		_report()
		return
	var packed := load(PAUSE_SCENE) as PackedScene
	if packed == null:
		_failures.append("не загружается %s" % PAUSE_SCENE)
		_report()
		return
	_menu = packed.instantiate() as Control
	add_child(_menu)
	await get_tree().process_frame
	await get_tree().process_frame
	await _case_fresh_profile()
	await _case_user_value_kept()
	await _case_legacy_zero_in_settings()
	await _case_corrupt_audio_cfg()
	await _case_user_mute_kept()
	await _case_fresh_profile_again()
	_cleanup()
	_report()


# --- Сценарии ----------------------------------------------------------------


## 1. Чистый профиль: пауза открыта/закрыта — Master должен остаться 1.0.
func _case_fresh_profile() -> void:
	_remove_user_files()
	_reload_from_disk()
	_check_near(
		"fresh: Master после загрузки",
		UiSettings.get_volume("Master"), 1.0,
		"ждали 1.0, получили %.4f" % UiSettings.get_volume("Master")
	)
	await _open_and_close_pause()
	_assert_master_saved("fresh", 1.0)
	_check_near(
		"fresh: AudioManager.get_bus_volume(Master)",
		float(_audio.call("get_bus_volume", "Master")), 1.0,
		"ждали 1.0, получили %.4f" % float(_audio.call("get_bus_volume", "Master"))
	)


## 2. Пользовательский выбор 0.35 из прошлой сессии не затирается.
func _case_user_value_kept() -> void:
	_remove_user_files()
	var config := ConfigFile.new()
	config.set_value("audio", "master", 0.35)
	config.set_value("audio", "music", float(UiSettings.DEFAULT_VOLUME["Music"]))
	config.set_value("audio", "sfx", float(UiSettings.DEFAULT_VOLUME["SFX"]))
	config.set_value("audio", "voice", float(UiSettings.DEFAULT_VOLUME["Voice"]))
	config.set_value("meta", "version", UiSettings.CONFIG_VERSION)
	var save_error := config.save(SETTINGS_PATH)
	if save_error != OK:
		_failures.append("не удалось подготовить settings.cfg (код %d)" % save_error)
		return
	_reload_from_disk()
	_check_near(
		"user 0.35: Master после загрузки",
		UiSettings.get_volume("Master"), 0.35,
		"ждали 0.35, получили %.4f" % UiSettings.get_volume("Master")
	)
	await _open_and_close_pause()
	_assert_master_saved("user 0.35", 0.35)


## 3. Старый «сиротский» ноль в settings.cfg (записан багом до t47) лечится:
##    он не помечен как осознанный мьют.
func _case_legacy_zero_in_settings() -> void:
	_remove_user_files()
	var config := ConfigFile.new()
	config.set_value("audio", "master", 0.0)
	config.set_value("audio", "music", float(UiSettings.DEFAULT_VOLUME["Music"]))
	config.set_value("audio", "sfx", float(UiSettings.DEFAULT_VOLUME["SFX"]))
	config.set_value("audio", "voice", float(UiSettings.DEFAULT_VOLUME["Voice"]))
	config.set_value("meta", "version", UiSettings.CONFIG_VERSION)
	config.save(SETTINGS_PATH)
	_reload_from_disk()
	_check_near(
		"старый ноль в settings.cfg: Master вылечен",
		UiSettings.get_volume("Master"), 1.0,
		"ждали 1.0, получили %.4f" % UiSettings.get_volume("Master")
	)
	await _open_and_close_pause()
	_assert_master_saved("старый ноль в settings.cfg", 1.0)


## 4. Испорченный audio.cfg (нули) не должен превращаться в тишину навсегда.
func _case_corrupt_audio_cfg() -> void:
	_remove_user_files()
	var config := ConfigFile.new()
	for bus in UiSettings.BUSES:
		config.set_value("bus", str(bus).to_lower(), 0.0)
	config.set_value("meta", "version", 2)
	var save_error := config.save(AUDIO_PATH)
	if save_error != OK:
		_failures.append("не удалось подготовить audio.cfg (код %d)" % save_error)
		return
	_audio.call("reload_audio_config")
	UiSettings.reload_settings()
	_check_near(
		"битый audio.cfg: Master вылечен",
		UiSettings.get_volume("Master"), 1.0,
		"ждали 1.0, получили %.4f" % UiSettings.get_volume("Master")
	)
	await _open_and_close_pause()
	_assert_master_saved("битый audio.cfg", 1.0)


## 5. Осознанный мьют ползунком (Master = 0) сохраняется как 0 и переживает
##    перезапуск (в settings.cfg есть отметка muted_master=true).
func _case_user_mute_kept() -> void:
	_remove_user_files()
	_reload_from_disk()
	var master_slider := _menu.get_node(
		"Dim/Center/Panel/Margin/VBox/MasterRow/MasterSlider"
	) as HSlider
	if master_slider == null:
		_failures.append("в PauseMenu нет MasterSlider")
		return
	_menu.call("open_menu")
	await get_tree().process_frame
	master_slider.value = 0.0
	await get_tree().process_frame
	_menu.call("close_menu")
	await get_tree().process_frame
	_check_near(
		"мьют игрока: settings.cfg master",
		_cfg_value(SETTINGS_PATH, "audio", "master"), 0.0,
		"ждали 0.0, получили %.4f" % _cfg_value(SETTINGS_PATH, "audio", "master")
	)
	var mute_flag := false
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		mute_flag = bool(config.get_value("audio", "muted_master", false))
	if not mute_flag:
		_failures.append("мьют игрока: нет отметки muted_master в settings.cfg")
	_check_near(
		"мьют игрока: AudioManager Master",
		float(_audio.call("get_bus_volume", "Master")), 0.0,
		"ждали 0.0, получили %.4f" % float(_audio.call("get_bus_volume", "Master"))
	)
	# «Перезапуск»: перечитываем настройки с диска — мьют должен сохраниться.
	_reload_from_disk()
	_check_near(
		"мьют игрока после перезапуска: Master",
		UiSettings.get_volume("Master"), 0.0,
		"ждали 0.0, получили %.4f" % UiSettings.get_volume("Master")
	)
	await _open_and_close_pause()
	_assert_master_saved("мьют игрока после перезапуска", 0.0)


## 6. Финальный чистый профиль — чтобы в отчёте были файлы с master=1.0.
func _case_fresh_profile_again() -> void:
	_remove_user_files()
	_reload_from_disk()
	await _open_and_close_pause()
	_assert_master_saved("финальный чистый профиль", 1.0)


# --- Вспомогательное ---------------------------------------------------------


func _open_and_close_pause() -> void:
	_menu.call("open_menu")
	await get_tree().process_frame
	await get_tree().process_frame
	if not bool(_menu.call("is_open")):
		_failures.append("PauseMenu не открылся")
	if not get_tree().paused:
		_failures.append("PauseMenu не поставил get_tree().paused = true")
	_menu.call("close_menu")
	await get_tree().process_frame
	await get_tree().process_frame
	if bool(_menu.call("is_open")):
		_failures.append("PauseMenu не закрылся")
	if get_tree().paused:
		_failures.append("PauseMenu не снял паузу")


func _assert_master_saved(label: String, expected: float) -> void:
	var settings_master := _cfg_value(SETTINGS_PATH, "audio", "master")
	var audio_master := _cfg_value(AUDIO_PATH, "bus", "master")
	_check_near(
		"%s: settings.cfg master" % label, settings_master, expected,
		"ждали %.3f, получили %.4f" % [expected, settings_master]
	)
	_check_near(
		"%s: audio.cfg master" % label, audio_master, expected,
		"ждали %.3f, получили %.4f" % [expected, audio_master]
	)
	_check_near(
		"%s: AudioManager Master" % label,
		float(_audio.call("get_bus_volume", "Master")), expected,
		"ждали %.3f, получили %.4f" % [expected, float(_audio.call("get_bus_volume", "Master"))]
	)


func _reload_from_disk() -> void:
	_audio.call("reload_audio_config")
	UiSettings.reload_settings()


func _remove_user_files() -> void:
	for path in [SETTINGS_PATH, AUDIO_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _cfg_value(path: String, section: String, key: String) -> float:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return -1.0
	return float(config.get_value(section, key, -1.0))


func _check_near(label: String, actual: float, expected: float, message: String) -> void:
	if absf(actual - expected) <= 0.001:
		print("[settings-smoke] OK %s = %.4f" % [label, actual])
		return
	_failures.append("%s: %s" % [label, message])


func _cleanup() -> void:
	get_tree().paused = false
	if _menu != null and bool(_menu.call("is_open")):
		_menu.call("close_menu")


func _report() -> void:
	if _failures.is_empty():
		print("[settings-smoke] Master не превращается в 0.0, выбор игрока сохраняется")
		print("T47 SETTINGS SMOKE OK")
		get_tree().quit(0)
		return
	for failure in _failures:
		printerr("T47 SETTINGS SMOKE FAIL: %s" % failure)
	print("T47 SETTINGS SMOKE FAILED (%d)" % _failures.size())
	get_tree().quit(1)
