extends Node
## AudioManager — автолоад: единственная точка воспроизведения звука в «Ночной смене».
##
## Контракт из docs/PHASE2.md:
##   play_sfx(name, position = null, volume_db = 0.0)
##   play_voice(dialogue_id, node_id) -> bool
##   set_bus_volume(bus_name, linear)
##   get_bus_volume(bus_name) -> float
##   is_voice_playing() -> bool
##   stop_voice()
##
## Удобное сверх контракта:
##   play_ambience(name, fade = 1.0, volume_db = 0.0) -> bool
##   stop_ambience(fade = 1.0)
##   play_music(name, fade = 1.0, volume_db = 0.0) -> bool
##   stop_music(fade = 1.0)
##   register_player(node)                  # шаги по движению игрока
##   set_footstep_surface(surface)          # "asphalt" (по умолчанию) / "wood"
##   get_footstep_surface() -> String
##   set_music_duck(db)                     # приглушение музыки на диалог
##   is_ready() -> bool                     # громкости загружены и применены
##   get_stream(name, category, loop) -> AudioStream
##   list_audio_files() -> PackedStringArray
##   get_stream_length(path) -> float
##   get_bus_table() -> Array[Dictionary]
##   save_audio_config(); reload_audio_config(); reset_bus_volumes()
##
## Сигнал: bus_volume_changed(bus_name, linear); audio_ready() — автолоад готов.
## get_bus_volume() до готовности отдаёт заводское значение из DEFAULT_BUS_DB,
## а не 0.0: UI не должен принимать «не загрузилось» за выбор пользователя.
##
## Каталоги: res://assets/audio/{sfx,ambience,music,voice}/<name>.wav
## Шины: Master, Music, SFX, Voice, Ambience (default_bus_layout.tres).
## Громкости по умолчанию: Music −12 dB, SFX −8 dB, Voice −4 dB, Ambience −18 dB.
## Текущие громкости (линейные 0…1) живут в user://audio.cfg, секция [bus].
## Версия конфига 2 (t28): у старых конфигов Ambience сбрасывается на −18 dB.
##
## WAV читается и без импорта: если ResourceLoader не знает файл, менеджер сам
## разбирает RIFF/PCM 16 бит. Это делает звук устойчивым к «чистому» клону проекта,
## где .godot/imported ещё не собран.
##
## Шаги: менеджер сам следит за CharacterBody3D игрока (группа "player"),
## копит пройденный путь и щёлкает вариантом поверхности; молчит на паузе,
## во время диалога и когда игрок стоит.

signal bus_volume_changed(bus_name: String, linear: float)
## Автолоад загрузил user://audio.cfg и применил шины. До этого сигнала
## get_bus_volume() отдаёт заводские значения, а не нули.
signal audio_ready()

const AUDIO_ROOT := "res://assets/audio"
const SFX_DIR := "res://assets/audio/sfx"
## Совместимость со старыми именами: данные/скрипты могли просить "gunshot",
## а реальный ассет называется "pistol_fire". Алиасы не меняют контракт
## play_sfx(), но не дают старому контенту падать с "файл не найден".
const SFX_ALIASES := {
	"gunshot": "pistol_fire",
	"gun_reload": "pistol_reload",
	"gun_empty": "pistol_empty",
}
const AMBIENCE_DIR := "res://assets/audio/ambience"
const MUSIC_DIR := "res://assets/audio/music"
const VOICE_DIR := "res://assets/audio/voice"
const VOICE_MANIFEST_PATH := "res://scripts/dialogue/data/voice_manifest.json"
const CONFIG_PATH := "user://audio.cfg"
const CONFIG_SECTION := "bus"

const BUS_NAMES := ["Master", "Music", "SFX", "Voice", "Ambience"]
const DEFAULT_BUS_DB := {
	"Master": 0.0,
	"Music": -12.0,
	"SFX": -8.0,
	"Voice": -4.0,
	# t28: дождь — фон, он не должен перекрывать шаги и голос. Было −14 dB.
	"Ambience": -18.0,
}
const SILENT_DB := -80.0
const MAX_LINEAR := 1.5
## Версия user://audio.cfg. 2 — шина Ambience опущена до −18 dB (t28).
const CONFIG_VERSION := 2
## Группа плееров-петель, которые создают другие системы (двигатель машины, t54).
## Менеджер глушит их при выходе, чтобы не копились playback'и.
const LOOP_PLAYER_GROUP := "audio_loop_player"

const SFX_POOL_SIZE := 12
const PLAYER_SEARCH_INTERVAL := 0.5
const DIALOGUE_GROUP := "player"
const FOOTSTEP_VARIANTS := {
	"asphalt": ["step_asphalt_01", "step_asphalt_02", "step_asphalt_03", "step_asphalt_04"],
	"wood": ["step_wood_01", "step_wood_02"],
}

# --- Состояние ---------------------------------------------------------------

var _bus_linear: Dictionary = {}
var _music_duck_db: float = 0.0
var _streams: Dictionary = {}

var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_cursor: int = 0
var _sfx_3d_root: Node3D = null

var _amb_players: Array[AudioStreamPlayer] = []
var _amb_active: int = 0
var _amb_name: String = ""
var _amb_volume_db: float = 0.0
var _amb_tweens: Array[Tween] = []

var _music_players: Array[AudioStreamPlayer] = []
var _music_active: int = 0
var _music_name: String = ""
var _music_volume_db: float = 0.0
var _music_tweens: Array[Tween] = []

var _voice: AudioStreamPlayer = null
var _voice_key: String = ""

var _player: Node3D = null
var _step_distance: float = 0.0
var _step_surface: String = "asphalt"
var _player_search_clock: float = 0.0

var _voice_manifest: Dictionary = {}
var _voice_manifest_loaded: bool = false

var _rng := RandomNumberGenerator.new()
var _shutdown_done: bool = false
## Загружены ли user://audio.cfg и заводские уровни (см. is_ready()).
var _initialized: bool = false
## --quit-after N из командной строки (headless-прогоны CI), 0 — не задан.
var _quit_after_frames: int = 0


func _ready() -> void:
	# Звук должен жить и на паузе: гашение музыки/окружения не замирает.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	_quit_after_frames = _read_quit_after_arg()
	_load_voice_manifest()
	reload_audio_config()
	_print_startup_summary()
	_initialized = true
	audio_ready.emit()


## Готов ли AudioManager (громкости загружены и применены).
##
## UI обязан спрашивать это до того, как сохранять «пользовательскую» громкость:
## до инициализации get_bus_volume() теперь всё равно возвращает заводское
## значение, но раньше можно было случайно записать в свои настройки ноль.
## Если нужно дождаться: `if not AudioManager.is_ready(): await AudioManager.audio_ready`.
func is_ready() -> bool:
	return _initialized


func _process(delta: float) -> void:
	if _shutdown_done:
		return
	_update_footsteps(delta)
	_poll_quit_after()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		shutdown()


func _exit_tree() -> void:
	shutdown()


# --- Выключение --------------------------------------------------------------


## `--quit-after N` завершает движок без сигнала сцене, поэтому звук гасим сами
## за пару кадров до выхода: иначе активные playback'и петель остаются в
## AudioServer до ObjectDB::cleanup и дают "10 ObjectDB instances were leaked".
func _read_quit_after_arg() -> int:
	var args := OS.get_cmdline_args()
	var index := 0
	while index < args.size():
		var arg := args[index]
		if arg == "--quit-after" and index + 1 < args.size():
			return maxi(int(args[index + 1]), 0)
		if arg.begins_with("--quit-after="):
			return maxi(int(arg.get_slice("=", 1)), 0)
		index += 1
	return 0


func _poll_quit_after() -> void:
	if _quit_after_frames <= 0 or _shutdown_done:
		return
	if Engine.get_process_frames() < _quit_after_frames - 3:
		return
	if is_inside_tree():
		get_tree().call_group("audio_ambience", "shutdown")
	shutdown()


## Останавливает все проигрыватели и отпускает звуковые ресурсы.
##
## Без этого на выходе остаются AudioStreamPlaybackWAV петель (дождь, музыка,
## зоны) и сами AudioStreamWAV — движок печатает
## "ObjectDB instances were leaked at exit". Поэтому перед завершением явно
## глушим каждый playback, останавливаем player и обнуляем stream (это снимает
## ссылку на WAV), а кэш потоков чистим.
func shutdown() -> void:
	if _shutdown_done:
		return
	_shutdown_done = true
	_stop_external_loop_players()
	_kill_tweens(_amb_tweens)
	_kill_tweens(_music_tweens)
	stop_voice()
	_amb_name = ""
	_music_name = ""
	for player in _amb_players:
		_stop_audio_player(player)
	for player in _music_players:
		_stop_audio_player(player)
	for player in _sfx_pool:
		_stop_audio_player(player)
	if _sfx_3d_root != null and is_instance_valid(_sfx_3d_root):
		for child in _sfx_3d_root.get_children():
			if child is AudioStreamPlayer3D:
				_stop_audio_player_3d(child as AudioStreamPlayer3D)
		_sfx_3d_root.queue_free()
		_sfx_3d_root = null
	_streams.clear()


## Плееры петель, живущие не у менеджера (двигатель машины): они сами
## добавляются в группу LOOP_PLAYER_GROUP, а на выходе их надо заглушить, иначе
## playback останется в AudioServer и всплывёт как утечка ObjectDB.
func _stop_external_loop_players() -> void:
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group(LOOP_PLAYER_GROUP):
		if not is_instance_valid(node):
			continue
		if node is AudioStreamPlayer3D:
			_stop_audio_player_3d(node as AudioStreamPlayer3D)
		elif node is AudioStreamPlayer:
			_stop_audio_player(node as AudioStreamPlayer)


func _stop_audio_player(player: AudioStreamPlayer) -> void:
	if player == null or not is_instance_valid(player):
		return
	_stop_playback(player)
	player.stop()
	player.stream = null


func _stop_audio_player_3d(player: AudioStreamPlayer3D) -> void:
	if player == null or not is_instance_valid(player):
		return
	_stop_playback(player)
	player.stop()
	player.stream = null


## Явный stop() у самого playback: player.stop() в некоторых версиях движка
## не доходит до AudioStreamPlayback._stop(), и объект остаётся в AudioServer.
## get_stream_playback() можно звать только у играющего player — у остановленного
## движок пишет "Player is inactive. Call play() before requesting ...".
func _stop_playback(player: Variant) -> void:
	if player == null or not is_instance_valid(player):
		return
	if not player.has_method("get_stream_playback"):
		return
	if not bool(player.get("playing")):
		return
	var playback: Variant = player.call("get_stream_playback")
	if playback == null:
		return
	if playback.has_method("stop"):
		playback.call("stop")


# --- Контракт: SFX -----------------------------------------------------------


## Короткий эффект. position: null — плоский звук (UI), Vector3/Node3D — 3D.
## Возвращает созданный проигрыватель (Node) или null, если звука нет.
func play_sfx(name: String, position: Variant = null, volume_db: float = 0.0) -> Node:
	if _shutdown_done or name.is_empty():
		return null
	var resolved_name := str(SFX_ALIASES.get(name, name))
	var path := _resolve_audio_path(resolved_name, SFX_DIR)
	if path.is_empty():
		push_warning("[audio] play_sfx: файл не найден — %s" % resolved_name)
		return null
	var stream := _get_stream(path, false)
	if stream == null:
		push_warning("[audio] play_sfx: не читается — %s" % path)
		return null
	if position != null:
		var positional := _play_sfx_3d(stream, position, volume_db)
		if positional != null:
			return positional
	return _play_sfx_flat(stream, volume_db)


# --- Контракт: озвучка -------------------------------------------------------


## Озвучка реплики. Ищет res://assets/audio/voice/<dialogue_id>_<node_id>.wav,
## затем voice_manifest.json. Нет файла — тихо возвращает false (диалог не ломается).
func play_voice(dialogue_id: String, node_id: String) -> bool:
	if _shutdown_done or dialogue_id.is_empty() or node_id.is_empty():
		return false
	var path := _resolve_voice_path(dialogue_id, node_id)
	if path.is_empty():
		return false
	var stream := _get_stream(path, false)
	if stream == null:
		push_warning("[audio] play_voice: не читается — %s" % path)
		return false
	_ensure_voice_player()
	stop_voice()
	_voice.stream = stream
	_voice.play()
	_voice_key = "%s_%s" % [dialogue_id, node_id]
	return true


func is_voice_playing() -> bool:
	return _voice != null and is_instance_valid(_voice) and _voice.playing


func stop_voice() -> void:
	_voice_key = ""
	if _voice != null and is_instance_valid(_voice):
		_voice.stop()
		_voice.stream = null


## Ключ текущей озвучки ("mila_mila_01") — для HUD/отладки.
func get_voice_key() -> String:
	return _voice_key


# --- Контракт: громкость шин ------------------------------------------------


## Линейная громкость шины (0…1). Значение сохраняется в user://audio.cfg.
func set_bus_volume(bus_name: String, linear: float) -> void:
	var bus := _canonical_bus(bus_name)
	if bus.is_empty():
		push_warning("[audio] set_bus_volume: неизвестная шина '%s'" % bus_name)
		return
	_bus_linear[bus] = clampf(linear, 0.0, MAX_LINEAR)
	_apply_bus(bus)
	save_audio_config()
	bus_volume_changed.emit(bus, float(_bus_linear[bus]))


## Линейная громкость шины. Для известной шины до инициализации отдаёт
## заводское значение (а не 0.0!), чтобы UI не принял «ещё не загрузилось»
## за выбор пользователя. Для неизвестной шины — 0.
func get_bus_volume(bus_name: String) -> float:
	var bus := _canonical_bus(bus_name)
	if bus.is_empty():
		return 0.0
	if not _bus_linear.has(bus):
		return db_to_linear(float(DEFAULT_BUS_DB.get(bus, 0.0)))
	return float(_bus_linear[bus])


## Громкость в дБ с учётом приглушения музыки (как её слышно сейчас).
func get_bus_volume_db(bus_name: String) -> float:
	var bus := _canonical_bus(bus_name)
	if bus.is_empty():
		return SILENT_DB
	var linear := get_bus_volume(bus)
	if linear <= 0.0001:
		return SILENT_DB
	var db := linear_to_db(linear)
	if bus == "Music":
		db += _music_duck_db
	return db


## Приглушение музыки на время диалога (дБ, отрицательное — тише).
func set_music_duck(db: float) -> void:
	_music_duck_db = clampf(db, -40.0, 12.0)
	_apply_bus("Music")


func get_music_duck() -> float:
	return _music_duck_db


## Вернуть заводские громкости (как в docs/PHASE2.md) и сохранить их.
func reset_bus_volumes() -> void:
	for bus in BUS_NAMES:
		_bus_linear[str(bus)] = db_to_linear(float(DEFAULT_BUS_DB[str(bus)]))
	_apply_all_buses()
	save_audio_config()


# --- Окружение и музыка ------------------------------------------------------


## Петля окружения (дождь, гул). Плавно сменяет предыдущую петлю.
func play_ambience(name: String, fade: float = 1.0, volume_db: float = 0.0) -> bool:
	if _shutdown_done:
		return false
	if name.is_empty():
		stop_ambience(fade)
		return false
	var stream := get_stream(name, "ambience", true)
	if stream == null:
		push_warning("[audio] play_ambience: нет звука '%s'" % name)
		return false
	_ensure_amb_players()
	if _amb_name == name and _amb_players[_amb_active].playing:
		_amb_volume_db = volume_db
		_amb_players[_amb_active].volume_db = volume_db
		return true
	var incoming: AudioStreamPlayer = _amb_players[1 - _amb_active]
	var outgoing: AudioStreamPlayer = _amb_players[_amb_active]
	_amb_active = 1 - _amb_active
	_amb_name = name
	_amb_volume_db = volume_db
	_kill_tweens(_amb_tweens)
	var duration := maxf(fade, 0.05)
	incoming.stream = stream
	incoming.volume_db = SILENT_DB
	incoming.play()
	var fade_in := create_tween()
	fade_in.tween_property(incoming, "volume_db", volume_db, duration)
	_amb_tweens.append(fade_in)
	if outgoing.playing:
		var fade_out := create_tween()
		fade_out.tween_property(outgoing, "volume_db", SILENT_DB, duration)
		fade_out.tween_callback(outgoing.stop)
		_amb_tweens.append(fade_out)
	return true


func stop_ambience(fade: float = 1.0) -> void:
	_amb_name = ""
	if _amb_players.is_empty():
		return
	_kill_tweens(_amb_tweens)
	var duration := maxf(fade, 0.05)
	for player in _amb_players:
		if player.playing:
			var tween := create_tween()
			tween.tween_property(player, "volume_db", SILENT_DB, duration)
			tween.tween_callback(player.stop)
			_amb_tweens.append(tween)


func get_ambience_name() -> String:
	return _amb_name


## Музыкальная петля с кроссфейдом.
func play_music(name: String, fade: float = 1.0, volume_db: float = 0.0) -> bool:
	if _shutdown_done:
		return false
	if name.is_empty():
		stop_music(fade)
		return false
	var stream := get_stream(name, "music", true)
	if stream == null:
		push_warning("[audio] play_music: нет звука '%s'" % name)
		return false
	_ensure_music_players()
	if _music_name == name and _music_players[_music_active].playing:
		_music_volume_db = volume_db
		_music_players[_music_active].volume_db = volume_db
		return true
	var incoming: AudioStreamPlayer = _music_players[1 - _music_active]
	var outgoing: AudioStreamPlayer = _music_players[_music_active]
	_music_active = 1 - _music_active
	_music_name = name
	_music_volume_db = volume_db
	_kill_tweens(_music_tweens)
	var duration := maxf(fade, 0.05)
	incoming.stream = stream
	incoming.volume_db = SILENT_DB
	incoming.play()
	var fade_in := create_tween()
	fade_in.tween_property(incoming, "volume_db", volume_db, duration)
	_music_tweens.append(fade_in)
	if outgoing.playing:
		var fade_out := create_tween()
		fade_out.tween_property(outgoing, "volume_db", SILENT_DB, duration)
		fade_out.tween_callback(outgoing.stop)
		_music_tweens.append(fade_out)
	return true


func stop_music(fade: float = 1.0) -> void:
	_music_name = ""
	if _music_players.is_empty():
		return
	_kill_tweens(_music_tweens)
	var duration := maxf(fade, 0.05)
	for player in _music_players:
		if player.playing:
			var tween := create_tween()
			tween.tween_property(player, "volume_db", SILENT_DB, duration)
			tween.tween_callback(player.stop)
			_music_tweens.append(tween)


func get_music_name() -> String:
	return _music_name


# --- Шаги --------------------------------------------------------------------


## Подключить игрока к шагам. Вызывать не обязательно: менеджер сам найдёт
## узел в группе "player". Нужно, если игрок появляется позже сцены.
func register_player(node: Node) -> void:
	_player = node as Node3D
	_step_distance = 0.0
	_player_search_clock = PLAYER_SEARCH_INTERVAL


func set_footstep_surface(surface: String) -> void:
	var key := surface.strip_edges().to_lower()
	if not FOOTSTEP_VARIANTS.has(key):
		key = "asphalt"
	if key == _step_surface:
		return
	_step_surface = key
	_step_distance = 0.0


func get_footstep_surface() -> String:
	return _step_surface


func get_registered_player() -> Node3D:
	return _player


# --- Загрузка звуков ---------------------------------------------------------


## AudioStream по имени и категории ("sfx"/"ambience"/"music"/"voice").
func get_stream(name: String, category: String = "sfx", loop: bool = false) -> AudioStream:
	var preferred := SFX_DIR
	match category:
		"ambience":
			preferred = AMBIENCE_DIR
		"music":
			preferred = MUSIC_DIR
		"voice":
			preferred = VOICE_DIR
	var path := _resolve_audio_path(name, preferred)
	if path.is_empty():
		return null
	return _get_stream(path, loop)


## Все .wav/.ogg в assets/audio (рекурсивно) — для отчётов и смоук-теста.
func list_audio_files() -> PackedStringArray:
	return _scan_dir(AUDIO_ROOT)


## Длительность звука по полному пути или имени (0.0 — не читается).
func get_stream_length(path: String) -> float:
	if path.is_empty():
		return 0.0
	var resolved := path
	if not resolved.begins_with("res://"):
		resolved = _resolve_audio_path(path, SFX_DIR)
	if resolved.is_empty():
		return 0.0
	var stream := _get_stream(resolved, false)
	if stream == null:
		return 0.0
	return maxf(stream.get_length(), 0.0)


func has_voice_manifest() -> bool:
	return _voice_manifest_loaded


func get_bus_table() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for bus in BUS_NAMES:
		var bus_name := str(bus)
		var index := AudioServer.get_bus_index(bus_name)
		rows.append({
			"name": bus_name,
			"index": index,
			"linear": float(_bus_linear.get(bus_name, 0.0)),
			"volume_db": get_bus_volume_db(bus_name),
			"default_db": float(DEFAULT_BUS_DB[bus_name]),
		})
	return rows


# --- Конфиг ------------------------------------------------------------------


func save_audio_config() -> void:
	var config := ConfigFile.new()
	for bus in BUS_NAMES:
		var bus_name := str(bus)
		config.set_value(CONFIG_SECTION, bus_name.to_lower(), float(_bus_linear.get(bus_name, 1.0)))
	config.set_value("meta", "version", CONFIG_VERSION)
	var error := config.save(CONFIG_PATH)
	if error != OK:
		push_warning("[audio] не удалось сохранить %s (код %d)" % [CONFIG_PATH, error])


func reload_audio_config() -> void:
	var config := ConfigFile.new()
	var loaded := config.load(CONFIG_PATH) == OK
	var stored_version := 0
	if loaded:
		stored_version = int(config.get_value("meta", "version", 0))
	# Миграция v1 → v2 (t28): шина Ambience стала тише (−14 → −18 dB).
	# Сбрасываем только её, остальные уровни пользователя не трогаем.
	var migrate_ambience := loaded and stored_version < CONFIG_VERSION
	for bus in BUS_NAMES:
		var bus_name := str(bus)
		var fallback := db_to_linear(float(DEFAULT_BUS_DB[bus_name]))
		var value := fallback
		if loaded and not (migrate_ambience and bus_name == "Ambience"):
			value = float(config.get_value(CONFIG_SECTION, bus_name.to_lower(), fallback))
		_bus_linear[bus_name] = clampf(value, 0.0, MAX_LINEAR)
	_apply_all_buses()
	if migrate_ambience:
		save_audio_config()
		print("[audio] конфиг v%d → v%d: Ambience %.1f dB" % [
			stored_version, CONFIG_VERSION, get_bus_volume_db("Ambience")
		])


# --- Внутреннее: шины --------------------------------------------------------


func _canonical_bus(bus_name: String) -> String:
	var wanted := bus_name.strip_edges()
	if wanted.is_empty():
		return ""
	for bus in BUS_NAMES:
		var exact := str(bus)
		if exact == wanted:
			return exact
	for bus in BUS_NAMES:
		var folded := str(bus)
		if folded.to_lower() == wanted.to_lower():
			return folded
	if AudioServer.get_bus_index(wanted) >= 0:
		return wanted
	return ""


func _apply_all_buses() -> void:
	for bus in BUS_NAMES:
		_apply_bus(str(bus))


func _apply_bus(bus_name: String) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	var linear := float(_bus_linear.get(bus_name, 0.0))
	var db := SILENT_DB
	if linear > 0.0001:
		db = linear_to_db(linear)
	if bus_name == "Music":
		db += _music_duck_db
	AudioServer.set_bus_volume_db(index, clampf(db, SILENT_DB, 24.0))


func _bus_or_master(bus_name: String) -> StringName:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return StringName(bus_name)
	return &"Master"


# --- Внутреннее: проигрыватели ----------------------------------------------


func _ensure_sfx_pool() -> void:
	if not _sfx_pool.is_empty():
		return
	var bus := _bus_or_master("SFX")
	for i in SFX_POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.name = "Sfx%d" % i
		player.bus = bus
		add_child(player)
		_sfx_pool.append(player)


func _play_sfx_flat(stream: AudioStream, volume_db: float) -> AudioStreamPlayer:
	_ensure_sfx_pool()
	if _sfx_pool.is_empty():
		return null
	var player: AudioStreamPlayer = _sfx_pool[_sfx_cursor % _sfx_pool.size()]
	_sfx_cursor = (_sfx_cursor + 1) % _sfx_pool.size()
	player.stop()
	player.stream = stream
	player.volume_db = volume_db
	player.play()
	return player


func _play_sfx_3d(stream: AudioStream, position: Variant, volume_db: float) -> AudioStreamPlayer3D:
	var root := _sound_root()
	if root == null:
		return null
	var target := Vector3.ZERO
	if position is Vector3:
		target = position
	elif position is Node3D:
		target = (position as Node3D).global_position
	else:
		return null
	var player := AudioStreamPlayer3D.new()
	player.name = "Sfx3D"
	player.stream = stream
	player.bus = _bus_or_master("SFX")
	player.volume_db = volume_db
	player.unit_size = 5.0
	player.max_distance = 45.0
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	root.add_child(player)
	player.global_position = target
	player.finished.connect(player.queue_free)
	player.play()
	return player


## Контейнер для 3D-одноразовых звуков: живёт в текущей сцене, чтобы у него
## был World3D и слушатель. Если сцена не Node3D (например, смоук-тест) — null.
func _sound_root() -> Node3D:
	if _sfx_3d_root != null and is_instance_valid(_sfx_3d_root) and _sfx_3d_root.is_inside_tree():
		return _sfx_3d_root
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var root := scene as Node3D
	if root == null:
		return null
	_sfx_3d_root = Node3D.new()
	_sfx_3d_root.name = "AudioOneShots"
	root.add_child(_sfx_3d_root)
	return _sfx_3d_root


func _ensure_amb_players() -> void:
	if not _amb_players.is_empty():
		return
	var bus := _bus_or_master("Ambience")
	for i in 2:
		var player := AudioStreamPlayer.new()
		player.name = "Ambience%d" % i
		player.bus = bus
		player.volume_db = SILENT_DB
		add_child(player)
		_amb_players.append(player)


func _ensure_music_players() -> void:
	if not _music_players.is_empty():
		return
	var bus := _bus_or_master("Music")
	for i in 2:
		var player := AudioStreamPlayer.new()
		player.name = "Music%d" % i
		player.bus = bus
		player.volume_db = SILENT_DB
		add_child(player)
		_music_players.append(player)


func _ensure_voice_player() -> void:
	if _voice != null and is_instance_valid(_voice):
		return
	_voice = AudioStreamPlayer.new()
	_voice.name = "VoicePlayer"
	_voice.bus = _bus_or_master("Voice")
	add_child(_voice)


func _kill_tweens(tweens: Array[Tween]) -> void:
	for tween in tweens:
		if tween != null and is_instance_valid(tween) and tween.is_valid():
			tween.kill()
	tweens.clear()


# --- Внутреннее: шаги --------------------------------------------------------


func _update_footsteps(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player_search_clock -= delta
		if _player_search_clock > 0.0:
			return
		_player_search_clock = PLAYER_SEARCH_INTERVAL
		var found := get_tree().get_first_node_in_group(DIALOGUE_GROUP)
		if found == null:
			return
		_player = found as Node3D
		if _player == null:
			return
	if get_tree().paused or _dialogue_active():
		_step_distance = 0.0
		return
	var body := _player as CharacterBody3D
	if body == null:
		return
	var planar_speed := Vector2(body.velocity.x, body.velocity.z).length()
	if planar_speed < 0.6 or not body.is_on_floor():
		_step_distance = 0.0
		return
	var stride := clampf(planar_speed * 0.42, 0.95, 2.7)
	_step_distance += planar_speed * delta
	if _step_distance < stride:
		return
	_step_distance = fmod(_step_distance, stride)
	_emit_footstep(planar_speed)


func _emit_footstep(speed: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var variants: Array = FOOTSTEP_VARIANTS.get(_step_surface, FOOTSTEP_VARIANTS["asphalt"])
	if variants.is_empty():
		return
	var variant_name := str(variants[_rng.randi_range(0, variants.size() - 1)])
	var loudness := lerpf(-3.5, 0.5, clampf((speed - 1.0) / 6.0, 0.0, 1.0))
	loudness += _rng.randf_range(-1.2, 1.2)
	var step_position := _player.global_position + Vector3(0.0, -0.05, 0.0)
	var player := play_sfx(variant_name, step_position, loudness) as AudioStreamPlayer3D
	if player == null:
		return
	player.pitch_scale = _rng.randf_range(0.94, 1.06)


func _dialogue_active() -> bool:
	var manager: Variant = get_node_or_null("/root/DialogueManager")
	if manager == null:
		return false
	if manager.has_method("is_active"):
		return bool(manager.is_active())
	return false


# --- Внутреннее: пути и WAV --------------------------------------------------


func _resolve_audio_path(name: String, preferred_dir: String) -> String:
	if name.is_empty():
		return ""
	if name.begins_with("res://"):
		return name if _file_exists(name) else ""
	var dirs := [preferred_dir, SFX_DIR, AMBIENCE_DIR, MUSIC_DIR, VOICE_DIR]
	var seen := {}
	for dir in dirs:
		var dir_path := str(dir)
		if seen.has(dir_path):
			continue
		seen[dir_path] = true
		var path := "%s/%s" % [dir_path, name]
		var lower := path.to_lower()
		if not lower.ends_with(".wav") and not lower.ends_with(".ogg"):
			path += ".wav"
		if _file_exists(path):
			return path
	return ""


func _resolve_voice_path(dialogue_id: String, node_id: String) -> String:
	var direct := "%s/%s_%s.wav" % [VOICE_DIR, dialogue_id, node_id]
	if _file_exists(direct):
		return direct
	var entry := _manifest_lookup(dialogue_id, node_id)
	if not entry.is_empty():
		var file := str(entry.get("file", ""))
		if not file.is_empty():
			if file.begins_with("res://"):
				if _file_exists(file):
					return file
			else:
				var file_path := "%s/%s" % [VOICE_DIR, file]
				if _file_exists(file_path):
					return file_path
		var voice_id := str(entry.get("voice_id", ""))
		if not voice_id.is_empty():
			var voice_path := "%s/%s.wav" % [VOICE_DIR, voice_id]
			if _file_exists(voice_path):
				return voice_path
	var by_key := "%s/%s.wav" % [VOICE_DIR, node_id]
	if _file_exists(by_key):
		return by_key
	return ""


func _manifest_lookup(dialogue_id: String, node_id: String) -> Dictionary:
	if not _voice_manifest_loaded:
		_load_voice_manifest()
	var entry: Variant = _voice_manifest.get(dialogue_id, null)
	if typeof(entry) == TYPE_DICTIONARY:
		var nodes: Dictionary = entry
		var by_node: Variant = nodes.get(node_id, null)
		if typeof(by_node) == TYPE_DICTIONARY:
			var as_dict: Dictionary = by_node
			return as_dict
		if typeof(by_node) == TYPE_STRING:
			return {"file": str(by_node)}
	var direct: Variant = _voice_manifest.get(node_id, null)
	if typeof(direct) == TYPE_DICTIONARY:
		var direct_dict: Dictionary = direct
		return direct_dict
	return {}


func _load_voice_manifest() -> void:
	_voice_manifest = {}
	_voice_manifest_loaded = false
	if not FileAccess.file_exists(VOICE_MANIFEST_PATH):
		return
	var raw := FileAccess.get_file_as_string(VOICE_MANIFEST_PATH)
	if raw.is_empty():
		return
	var json := JSON.new()
	if json.parse(raw) != OK:
		push_warning("[audio] voice_manifest.json: строка %d — %s" % [
			json.get_error_line(), json.get_error_message()
		])
		return
	if typeof(json.data) == TYPE_DICTIONARY:
		_voice_manifest = json.data
		_voice_manifest_loaded = not _voice_manifest.is_empty()


func _file_exists(path: String) -> bool:
	if FileAccess.file_exists(path):
		return true
	return ResourceLoader.exists(path)


func _get_stream(path: String, loop: bool) -> AudioStream:
	var key := "%s|loop=%s" % [path, str(loop)]
	var cached: Variant = _streams.get(key, null)
	if cached != null:
		return cached as AudioStream
	var stream: AudioStream = null
	if ResourceLoader.exists(path):
		stream = load(path) as AudioStream
		if stream != null and loop:
			# Импортированный ресурс общий: копируем, чтобы включить петлю только здесь.
			stream = stream.duplicate() as AudioStream
	if stream == null and FileAccess.file_exists(path):
		stream = _read_wav(path)
	if stream == null:
		return null
	if stream is AudioStreamWAV:
		_configure_wav(stream as AudioStreamWAV, loop)
	_streams[key] = stream
	return stream


func _configure_wav(wav: AudioStreamWAV, loop: bool) -> void:
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = _wav_frame_count(wav)
	else:
		wav.loop_mode = AudioStreamWAV.LOOP_DISABLED


func _wav_frame_count(wav: AudioStreamWAV) -> int:
	if wav == null:
		return 0
	var bytes_per_sample := 2
	var channels := 2 if wav.stereo else 1
	var divisor := bytes_per_sample * channels
	if divisor <= 0:
		return 0
	return int(wav.data.size() / divisor)


## Ручной разбор PCM WAV (16 бит) — работает без импорта ресурсов.
func _read_wav(path: String) -> AudioStream:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 44:
		return null
	if bytes.slice(0, 4).get_string_from_ascii() != "RIFF":
		return null
	if bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		return null
	var offset := 12
	var total := bytes.size()
	var channels := 1
	var sample_rate := 44100
	var bits := 16
	var format_tag := 1
	var pcm := PackedByteArray()
	while offset + 8 <= total:
		var chunk_id := bytes.slice(offset, offset + 4).get_string_from_ascii()
		var chunk_size := int(bytes.decode_u32(offset + 4))
		var data_start := offset + 8
		if chunk_id == "fmt " and data_start + 16 <= total:
			format_tag = int(bytes.decode_u16(data_start))
			channels = int(bytes.decode_u16(data_start + 2))
			sample_rate = int(bytes.decode_u32(data_start + 4))
			bits = int(bytes.decode_u16(data_start + 14))
		elif chunk_id == "data":
			var data_end := mini(data_start + chunk_size, total)
			pcm = bytes.slice(data_start, data_end)
			break
		if chunk_size < 0:
			break
		offset = data_start + chunk_size + (chunk_size % 2)
	if pcm.is_empty() or channels < 1:
		return null
	if format_tag != 1:
		push_warning("[audio] %s: только PCM WAV (format tag %d)" % [path, format_tag])
		return null
	if bits != 16:
		push_warning("[audio] %s: поддерживается только 16 бит (bits=%d)" % [path, bits])
		return null
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = channels >= 2
	wav.mix_rate = sample_rate
	wav.data = pcm
	return wav


func _scan_dir(dir_path: String) -> PackedStringArray:
	var result := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return result
	for sub in DirAccess.get_directories_at(dir_path):
		result.append_array(_scan_dir("%s/%s" % [dir_path, sub]))
	for file in DirAccess.get_files_at(dir_path):
		var lower := file.to_lower()
		if lower.ends_with(".wav") or lower.ends_with(".ogg"):
			result.append("%s/%s" % [dir_path, file])
	return result


func _print_startup_summary() -> void:
	var files := list_audio_files()
	var bus_rows := get_bus_table()
	var bus_text := PackedStringArray()
	for row in bus_rows:
		bus_text.append("%s %.1f dB" % [row["name"], row["volume_db"]])
	print("[audio] AudioManager готов: шин %d [%s], файлов %d, озвучка: %s" % [
		bus_rows.size(),
		", ".join(bus_text),
		files.size(),
		"манифест" if _voice_manifest_loaded else "нет манифеста (тихий режим)",
	])
