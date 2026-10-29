extends Node
## T12 AUDIO SMOKE — headless-проверка аудиосистемы «Ночной смены».
##
## Запуск (без окна, отдельной сценой — автолоады при этом поднимаются):
##   tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . \
##       tests/audio_smoke.tscn --log-file tools\t12_smoke.log
##
## Что проверяет:
##   1) автолоад AudioManager существует;
##   2) шины Master/Music/SFX/Voice/Ambience есть в AudioServer;
##   3) в assets/audio ≥ 12 файлов, каждый читается и длиннее 0.05 с;
##   4) ключевые петли на месте и нужной длины (дождь ≥ 20 с, музыка ≥ 40 с);
##   5) play_sfx/play_ambience/play_music не падают, отсутствующая озвучка — тихо false;
##   6) громкость шины сохраняется в user://audio.cfg, читается после reload;
##   7) поверхность шагов переключается.
##
## Успех — строка "T12 AUDIO SMOKE OK" в логе и код возврата 0.
## Провал — строки "T12 AUDIO SMOKE FAIL: …" и код возврата 1.

const REQUIRED_BUSES := ["Master", "Music", "SFX", "Voice", "Ambience"]
const MIN_SOUND_FILES := 12
const AUDIO_ROOT := "res://assets/audio"
const CONFIG_PATH := "user://audio.cfg"

var _failures: Array[String] = []
var _audio: Variant = null


func _ready() -> void:
	_audio = get_node_or_null("/root/AudioManager")
	_check_autoload()
	_check_buses()
	_check_files()
	_check_loops()
	_check_playback()
	_check_surface()
	_check_volume_persistence()
	_report()


# --- Проверки ----------------------------------------------------------------


func _check_autoload() -> void:
	if _audio == null:
		_failures.append("нет автолоада AudioManager (/root/AudioManager)")
		return
	print("[smoke] AudioManager: да, манифест озвучки: %s" % str(_audio.has_voice_manifest()))


func _check_buses() -> void:
	var rows: Array = _audio.get_bus_table() if _audio != null else []
	for bus in REQUIRED_BUSES:
		var index := AudioServer.get_bus_index(bus)
		if index < 0:
			_failures.append("нет шины '%s' в AudioServer" % bus)
			continue
		print("[smoke] шина %-8s idx=%d, %6.1f dB, linear=%.3f" % [
			bus, index, AudioServer.get_bus_volume_db(index),
			float(_audio.get_bus_volume(bus)) if _audio != null else 0.0,
		])
	if AudioServer.get_bus_count() < REQUIRED_BUSES.size():
		_failures.append("шин в AudioServer %d < %d" % [
			AudioServer.get_bus_count(), REQUIRED_BUSES.size()
		])
	if _audio != null and rows.size() != REQUIRED_BUSES.size():
		_failures.append("get_bus_table() вернул %d строк вместо %d" % [
			rows.size(), REQUIRED_BUSES.size()
		])


func _check_files() -> void:
	if _audio == null:
		return
	var files: PackedStringArray = _audio.list_audio_files()
	print("[smoke] файлов в assets/audio: %d" % files.size())
	if files.size() < MIN_SOUND_FILES:
		_failures.append("файлов %d < %d" % [files.size(), MIN_SOUND_FILES])
		return
	var broken := 0
	var total_seconds := 0.0
	for path in files:
		var length := float(_audio.get_stream_length(path))
		total_seconds += length
		if length <= 0.05:
			broken += 1
			_failures.append("не грузится или короче 0.05 с: %s (%.3f с)" % [path, length])
	print("[smoke] загружено файлов: %d, битых: %d, суммарно %.1f с" % [
		files.size(), broken, total_seconds
	])


func _check_loops() -> void:
	if _audio == null:
		return
	var loops := [
		{"name": "rain_light_loop", "category": "ambience", "min": 20.0},
		{"name": "rain_heavy_loop", "category": "ambience", "min": 20.0},
		{"name": "city_hum_loop", "category": "ambience", "min": 15.0},
		{"name": "neon_hum_loop", "category": "ambience", "min": 15.0},
		{"name": "water_wind_loop", "category": "ambience", "min": 15.0},
		{"name": "mus_night_shift_loop", "category": "music", "min": 40.0},
	]
	for entry in loops:
		var data: Dictionary = entry
		var category := str(data["category"])
		var sound_name := str(data["name"])
		var stream: AudioStream = _audio.get_stream(sound_name, category, true)
		if stream == null:
			_failures.append("нет петли %s/%s.wav" % [category, sound_name])
			continue
		var stream_length := stream.get_length()
		if stream_length < float(data["min"]):
			_failures.append("петля %s короче %.0f с (%.2f с)" % [
				sound_name, float(data["min"]), stream_length
			])
		print("[smoke] петля %-22s %6.2f с" % [sound_name, stream_length])


func _check_playback() -> void:
	if _audio == null:
		return
	var click: Variant = _audio.play_sfx("ui_click")
	if click == null:
		_failures.append("play_sfx('ui_click') вернул null")
	if _audio.play_voice("__no_such_dialogue__", "__no_such_node__"):
		_failures.append("play_voice для отсутствующего файла вернул true")
	if _audio.is_voice_playing():
		_failures.append("is_voice_playing() = true после пустой озвучки")
	_audio.stop_voice()
	if not bool(_audio.play_ambience("rain_light_loop", 0.1, -6.0)):
		_failures.append("play_ambience('rain_light_loop') не запустился")
	if not bool(_audio.play_music("mus_night_shift_loop", 0.1, -6.0)):
		_failures.append("play_music('mus_night_shift_loop') не запустился")
	if str(_audio.get_ambience_name()) != "rain_light_loop":
		_failures.append("get_ambience_name() = '%s'" % str(_audio.get_ambience_name()))
	_audio.play_sfx("door_creak", Vector3(1.0, 0.0, 2.0), -3.0)
	_audio.stop_ambience(0.1)
	_audio.stop_music(0.1)
	print("[smoke] воспроизведение: sfx/ambience/music вызваны без ошибок")


func _check_surface() -> void:
	if _audio == null:
		return
	var original := str(_audio.get_footstep_surface())
	_audio.set_footstep_surface("wood")
	if str(_audio.get_footstep_surface()) != "wood":
		_failures.append("поверхность шагов не переключилась на 'wood'")
	_audio.set_footstep_surface("unknown-surface")
	if str(_audio.get_footstep_surface()) != "asphalt":
		_failures.append("неизвестная поверхность не откатилась в 'asphalt'")
	_audio.set_footstep_surface(original)
	print("[smoke] поверхность шагов: переключение wood/asphalt работает")


func _check_volume_persistence() -> void:
	if _audio == null:
		return
	var original := float(_audio.get_bus_volume("SFX"))
	var probe := 0.42
	_audio.set_bus_volume("SFX", probe)
	var immediate := float(_audio.get_bus_volume("SFX"))
	if absf(immediate - probe) > 0.001:
		_failures.append("get_bus_volume после set = %.4f, ждали %.4f" % [immediate, probe])
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		_failures.append("user://audio.cfg не читается после set_bus_volume")
	else:
		var saved := float(config.get_value("bus", "sfx", -1.0))
		if absf(saved - probe) > 0.001:
			_failures.append("в user://audio.cfg sfx=%.4f, ждали %.4f" % [saved, probe])
	_audio.reload_audio_config()
	var reloaded := float(_audio.get_bus_volume("SFX"))
	if absf(reloaded - probe) > 0.001:
		_failures.append("после reload_audio_config SFX=%.4f, ждали %.4f" % [reloaded, probe])
	var db := float(_audio.get_bus_volume_db("SFX"))
	print("[smoke] громкость SFX: %.3f linear = %.1f dB, сохранена в %s" % [
		reloaded, db, CONFIG_PATH
	])
	_audio.set_bus_volume("SFX", original)


# --- Итог --------------------------------------------------------------------


func _report() -> void:
	if _failures.is_empty():
		print("[smoke] шины, %d+ файлов, воспроизведение и конфиг — в порядке" % MIN_SOUND_FILES)
		print("T12 AUDIO SMOKE OK")
		get_tree().quit(0)
		return
	for failure in _failures:
		printerr("T12 AUDIO SMOKE FAIL: %s" % failure)
	print("T12 AUDIO SMOKE FAILED (%d)" % _failures.size())
	get_tree().quit(1)
