extends Node
## Music playlist smoke: саундтрек из assets/audio/music играется плейлистом —
## на старте выбирается один из треков, по концу включается следующий.
##
## Проверяет:
##   1) оба трека плейлиста находятся и грузятся (mp3 в Godot 4.7.2 — AudioStreamMP3);
##   2) play_music(..., loop = false) доводит трек до конца и шлёт music_finished,
##      назвав именно доигравший трек;
##   3) AmbienceController собирает очередь, играет трек из неё и после конца
##      трека переключается на следующий по кругу.
##
## Запуск:
##   tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . tests/music_playlist_smoke.tscn
## Успех: код 0 и строка "MUSIC PLAYLIST SMOKE OK".

const MUSIC_TRACKS := ["634", "634 master"]
const OK_MARKER := "MUSIC PLAYLIST SMOKE OK"
## Треки длинные (3 минуты); короче — значит загрузился не тот файл.
const MIN_TRACK_LENGTH := 60.0

var _audio: Variant = null
var _failures: Array[String] = []
var _checks: int = 0
## Лямбда в GDScript захватывает локальные переменные по значению, поэтому
## имя доигравшего трека копим в поле, а не в локальной переменной.
var _finished_track: String = ""


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== MUSIC PLAYLIST SMOKE START ===")
	await get_tree().process_frame
	_audio = get_node_or_null("/root/AudioManager")
	_check("автолоад AudioManager поднят", _audio != null, "нет /root/AudioManager")
	if _audio == null:
		_finish()
		return

	_audio.stop_music(0.05)
	_check_tracks()
	await _check_finished_signal()
	await _check_ambience_playlist()
	_finish()


## 1. Треки плейлиста реально есть и грузятся как не-петля.
func _check_tracks() -> void:
	for track in MUSIC_TRACKS:
		var stream: AudioStream = _audio.get_stream(track, "music", false)
		_check("трек '%s' найден" % track, stream != null, "get_stream вернул null")
		if stream == null:
			continue
		var track_length := stream.get_length()
		_check(
			"трек '%s' длиной не меньше %.0f с" % [track, MIN_TRACK_LENGTH],
			track_length >= MIN_TRACK_LENGTH,
			"длина %.2f с" % track_length,
		)
		print("[music] %s: %.2f с, %s" % [track, track_length, stream.get_class()])
		var looped: AudioStream = _audio.get_stream(track, "music", true)
		_check("петля '%s' тоже грузится" % track, looped != null, "get_stream(loop=true) = null")


## 2. Конец трека в режиме плейлиста даёт сигнал music_finished.
func _check_finished_signal() -> void:
	_check("сигнал music_finished объявлен", _audio.has_signal("music_finished"), "нет сигнала")
	if not _audio.has_signal("music_finished"):
		return
	var on_finished := func(track: String) -> void:
		_finished_track = track
	_audio.music_finished.connect(on_finished)
	_check(
		"play_music('634', loop = false) запустился",
		bool(_audio.play_music("634", 0.05, -6.0, false)),
		"play_music вернул false",
	)
	var players: Array = _audio._music_players
	var active := int(_audio._music_active)
	if players.is_empty():
		_check("плееры музыки созданы", false, "нет _music_players")
		_audio.music_finished.disconnect(on_finished)
		return
	var player: AudioStreamPlayer = players[active]
	if player.stream != null:
		# Сразу после play() движок ещё не начал микшировать, и seek теряется:
		# даём паре кадров пройти, потом прыгаем за четверть секунды до конца.
		await get_tree().process_frame
		await get_tree().process_frame
		player.seek(maxf(player.stream.get_length() - 0.25, 0.0))
		print("[music] после seek: позиция %.2f с при длине %.2f с" % [
			player.get_playback_position(), player.stream.get_length(),
		])
	# Ждём по «настенным» часам: в headless кадры идут без ограничения FPS.
	var started := Time.get_ticks_msec()
	while _finished_track.is_empty() and Time.get_ticks_msec() - started < 4000:
		await get_tree().process_frame
	var waited := Time.get_ticks_msec() - started
	_check("music_finished пришёл", not _finished_track.is_empty(), "сигнала нет за %d мс" % waited)
	_check("music_finished назвал '634'", _finished_track == "634", "пришло '%s'" % _finished_track)
	if _audio.music_finished.is_connected(on_finished):
		_audio.music_finished.disconnect(on_finished)
	_audio.stop_music(0.05)
	await get_tree().process_frame


## 3. AmbienceController: очередь собрана, играет свой трек, по концу — следующий.
func _check_ambience_playlist() -> void:
	var controller_script: Script = load("res://scripts/audio/ambience_controller.gd")
	_check("скрипт ambience_controller.gd загрузился", controller_script != null, "load вернул null")
	if controller_script == null:
		return
	var controller: Node = controller_script.new()
	controller.music_playlist = PackedStringArray(MUSIC_TRACKS)
	controller.music_shuffle = true
	controller.rain_enabled = false
	controller.auto_register_player = false
	add_child(controller)
	# _start() у контроллера вызывается через call_deferred — даём кадр-другой.
	await get_tree().process_frame
	await get_tree().process_frame

	var queue: Array = controller.get_music_queue()
	_check("очередь плейлиста = оба трека", queue.size() == MUSIC_TRACKS.size(), "размер %d" % queue.size())
	for track in queue:
		_check("в очереди только известные треки ('%s')" % str(track), MUSIC_TRACKS.has(str(track)))

	var first := str(controller.get_current_music())
	_check("на старте играет трек из плейлиста ('%s')" % first, MUSIC_TRACKS.has(first), "играет '%s'" % first)

	# Эмулируем конец трека — контроллер обязан включить следующий.
	_audio.music_finished.emit(first)
	await get_tree().process_frame
	var second := str(controller.get_current_music())
	_check("после конца трека играет другой ('%s')" % second, second != first and MUSIC_TRACKS.has(second),
		"было '%s', стало '%s'" % [first, second])

	_audio.stop_music(0.05)
	controller.queue_free()
	await get_tree().process_frame


func _check(what: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if passed:
		print("[OK] %s" % what)
		return
	var line := "[FAIL] %s" % what
	if not detail.is_empty():
		line += " — %s" % detail
	print(line)
	_failures.append(what)


func _finish() -> void:
	print("=== MUSIC PLAYLIST SMOKE END ===")
	if _failures.is_empty():
		print("%s (проверок: %d)" % [OK_MARKER, _checks])
		get_tree().quit(0)
		return
	print("ПРОВАЛЕНО %d из %d:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - %s" % failure)
	get_tree().quit(1)
