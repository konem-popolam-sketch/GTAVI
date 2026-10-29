extends Node3D
## AmbienceController — звук окружения «Ночной смены» на сцене.
##
## Что делает:
##   1) держит «подложку» дождя на шине Ambience и раз в ~34 с плавно меняет
##      петлю (лёгкий/сильный дождь), чтобы квартал не звучал одинаково;
##   2) держит точечные зоны (неон у магазина, вода/ветер у пирса, гул у забора),
##      у каждой свой AudioStreamPlayer3D: панорама и затухание считаются
##      по позиции относительно камеры;
##   3) переключает поверхность шагов игрока (пирс — дерево);
##   4) регистрирует игрока в AudioManager, чтобы шаги заработали без правок
##      scenes/player/player.tscn;
##   5) играет ночной саундтрек из плейлиста (music_playlist): на старте
##      порядок перемешивается, дальше треки идут друг за другом по кругу.
##
## Зоны можно задать в инспекторе (Array[Dictionary]), а можно оставить пустыми —
## тогда берутся координаты из scenes/world/block.tscn.
## Ключи зоны:
##   id            — String, имя узла-проигрывателя
##   sound         — String, файл в assets/audio/ambience без .wav ("" — тихая зона)
##   poi           — String, имя Marker3D в World (POI_Shop, POI_Pier…), опционально
##   position      — Vector3, если poi нет
##   height        — float, смещение по Y от POI (по умолчанию 0)
##   inner_radius  — float, ближе — полная громкость
##   outer_radius  — float, дальше — тишина
##   volume_db     — float, громкость зоны на пике
##   surface       — String, "wood"/"asphalt" — поверхность шагов в зоне
##
## Ничего, кроме звука, этот узел не трогает: управление, диалоги и пауза
## остаются за своими системами.

@export_group("Дождь")
@export var rain_enabled: bool = true
@export var rain_variants: Array[String] = ["rain_light_loop", "rain_heavy_loop"]
@export var rain_volume_db: float = -2.0
@export var rain_change_seconds: float = 34.0

@export_group("Музыка")
@export var music_enabled: bool = true
## Плейлист: имена файлов из assets/audio/music (с расширением или без).
## На старте порядок перемешивается, дальше треки идут друг за другом по кругу.
@export var music_playlist: PackedStringArray = PackedStringArray(["634", "634 master"])
## Перемешивать порядок при каждом заходе — первым может зайти любой трек.
@export var music_shuffle: bool = true
## Устаревшее одиночное имя трека: работает, только если music_playlist пуст.
@export var music_name: String = ""
@export var music_volume_db: float = -3.0
@export var music_fade_seconds: float = 3.0

@export_group("Зоны")
@export var zones: Array[Dictionary] = []
@export var zone_fade_speed: float = 3.0

@export_group("Игрок")
@export var auto_register_player: bool = true
@export var player_search_interval: float = 0.5

@export_group("Отладка")
@export var verbose: bool = false

const SURFACE_DEFAULT := "asphalt"

var _audio: Variant = null
var _player: Node3D = null

var _rain_clock: float = 0.0
var _rain_current: String = ""

var _zone_state: Dictionary = {}
var _surface_current: String = SURFACE_DEFAULT
var _search_clock: float = 0.0
var _rng := RandomNumberGenerator.new()

var _music_queue: Array[String] = []
var _music_cursor: int = 0
var _music_started: bool = false


func _ready() -> void:
	# Группа нужна автолоаду: перед выходом он глушит зоны через call_group().
	add_to_group("audio_ambience")
	_audio = get_node_or_null("/root/AudioManager")
	_rng.randomize()
	if _audio == null:
		push_warning("[ambience] нет автолоада AudioManager — окружение отключено")
		return
	if zones.is_empty():
		zones = _build_default_zones()
	call_deferred("_start")


func _process(delta: float) -> void:
	if _audio == null:
		return
	_update_player_reference(delta)
	_update_zones(delta)
	_update_rain(delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		shutdown()


func _exit_tree() -> void:
	shutdown()


## Глушит зоны и отпускает их потоки (иначе AudioStreamPlaybackWAV зон
## остаются в AudioServer и всплывают на выходе как утечка ObjectDB).
func shutdown() -> void:
	for id in _zone_state.keys():
		var state: Dictionary = _zone_state[id]
		var player_variant: Variant = state.get("player", null)
		if player_variant == null or not is_instance_valid(player_variant):
			continue
		var player := player_variant as AudioStreamPlayer3D
		# get_stream_playback() безопасен только у играющего игрока.
		if player.playing:
			var playback: Variant = player.get_stream_playback()
			if playback != null and playback.has_method("stop"):
				playback.call("stop")
		player.stop()
		player.stream = null
	_zone_state.clear()
	_audio = null


# --- Публичный API -----------------------------------------------------------


## Заново собрать зоны (например, после пересборки района).
func rebuild_zones() -> void:
	for id in _zone_state.keys():
		var state: Dictionary = _zone_state[id]
		var player: Variant = state.get("player", null)
		if player != null and is_instance_valid(player):
			(player as Node).queue_free()
	_zone_state.clear()
	_spawn_zones()


## Позиции зон (для отчёта/тестов): {id: Vector3}.
func get_zone_positions() -> Dictionary:
	var result := {}
	for id in _zone_state.keys():
		var state: Dictionary = _zone_state[id]
		result[id] = state.get("position", Vector3.ZERO)
	return result


func get_current_rain() -> String:
	return _rain_current


## Порядок треков на этот заход (после перемешивания).
func get_music_queue() -> Array[String]:
	return _music_queue.duplicate()


## Что играет прямо сейчас ("" — музыки нет).
func get_current_music() -> String:
	if _audio == null or not _music_started:
		return ""
	return str(_audio.get_music_name())


# --- Старт -------------------------------------------------------------------


func _start() -> void:
	if _audio == null:
		return
	_spawn_zones()
	_find_player()
	_update_rain(0.0)
	if music_enabled:
		_start_music()
	if verbose:
		print("[ambience] зон: %d, дождь: %s, музыка: %s" % [
			_zone_state.size(),
			"вкл" if rain_enabled else "выкл",
			", ".join(_music_queue) if music_enabled else "выкл",
		])


# --- Музыка ------------------------------------------------------------------


## Собрать очередь: сначала плейлист, иначе устаревший одиночный music_name.
func _build_music_queue() -> Array[String]:
	var result: Array[String] = []
	for track in music_playlist:
		var track_name := str(track).strip_edges()
		if not track_name.is_empty() and not result.has(track_name):
			result.append(track_name)
	var legacy := music_name.strip_edges()
	if result.is_empty() and not legacy.is_empty():
		result.append(legacy)
	return result


## Перемешать очередь один раз на старте: «при заходе рандомно выбирается трек».
## Дальше треки идут по кругу в этом порядке («друг за другом»).
func _shuffle_music_queue() -> void:
	if not music_shuffle or _music_queue.size() < 2:
		return
	for index in range(_music_queue.size() - 1, 0, -1):
		var swap_with := _rng.randi_range(0, index)
		var tmp := _music_queue[index]
		_music_queue[index] = _music_queue[swap_with]
		_music_queue[swap_with] = tmp


func _start_music() -> void:
	if _audio == null:
		return
	_music_queue = _build_music_queue()
	if _music_queue.is_empty():
		push_warning("[ambience] музыка: пустой плейлист — треки не играют")
		return
	_shuffle_music_queue()
	if _audio.has_signal("music_finished") and not _audio.music_finished.is_connected(_on_music_finished):
		_audio.music_finished.connect(_on_music_finished)
	_music_started = true
	_music_cursor = 0
	_play_music_at_cursor()


func _play_music_at_cursor() -> void:
	if not _music_started or _music_queue.is_empty() or _audio == null:
		return
	# Один проход по очереди: битый/пропавший трек пропускаем, а не зацикливаемся.
	for _attempt in _music_queue.size():
		var track := _music_queue[_music_cursor]
		if bool(_audio.play_music(track, music_fade_seconds, music_volume_db, false)):
			if verbose:
				print("[ambience] музыка: %s" % track)
			return
		push_warning("[ambience] музыка: нет трека '%s'" % track)
		_music_cursor = (_music_cursor + 1) % _music_queue.size()


func _on_music_finished(_track: String) -> void:
	if not _music_started or _music_queue.is_empty():
		return
	_music_cursor = (_music_cursor + 1) % _music_queue.size()
	_play_music_at_cursor()


func _build_default_zones() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	# Неон «Луны» — тёплый электрический гул у магазина.
	result.append({
		"id": "shop_neon",
		"sound": "neon_hum_loop",
		"poi": "POI_Shop",
		"position": Vector3(-4.0, 2.0, -10.9),
		"height": 2.0,
		"inner_radius": 3.5,
		"outer_radius": 14.0,
		"volume_db": -4.0,
		"surface": "",
	})
	# Пирс: вода и ветер с моря.
	result.append({
		"id": "pier_water",
		"sound": "water_wind_loop",
		"poi": "POI_Pier",
		"position": Vector3(0.0, -0.4, 37.0),
		"height": 0.3,
		"inner_radius": 5.0,
		"outer_radius": 20.0,
		"volume_db": -3.0,
		"surface": "",
	})
	# Настил пирса — шаги по дереву.
	result.append({
		"id": "pier_wood",
		"sound": "",
		"poi": "POI_Pier",
		"position": Vector3(0.0, -0.9, 33.0),
		"height": 0.0,
		"inner_radius": 6.5,
		"outer_radius": 8.5,
		"volume_db": 0.0,
		"surface": "wood",
	})
	# Переулок у забора — далёкий город.
	result.append({
		"id": "alley_hum",
		"sound": "city_hum_loop",
		"poi": "POI_Fence",
		"position": Vector3(-8.2, 1.5, 11.5),
		"height": 1.5,
		"inner_radius": 3.0,
		"outer_radius": 12.0,
		"volume_db": -9.0,
		"surface": "",
	})
	return result


# --- Зоны --------------------------------------------------------------------


func _spawn_zones() -> void:
	for zone in zones:
		if typeof(zone) != TYPE_DICTIONARY:
			continue
		var data: Dictionary = zone
		var id := str(data.get("id", "zone_%d" % _zone_state.size()))
		if _zone_state.has(id):
			id = "%s_%d" % [id, _zone_state.size()]
		var zone_position := _resolve_zone_position(data)
		var state := {
			"data": data,
			"position": zone_position,
			"player": null,
		}
		_zone_state[id] = state
		var sound := str(data.get("sound", ""))
		if sound.is_empty():
			continue
		var stream: AudioStream = _audio.get_stream(sound, "ambience", true)
		if stream == null:
			push_warning("[ambience] зона '%s': нет файла '%s'" % [id, sound])
			continue
		var player := AudioStreamPlayer3D.new()
		player.name = "Zone_%s" % id
		player.stream = stream
		player.bus = "Ambience"
		player.volume_db = -80.0
		player.unit_size = 8.0
		player.max_distance = 60.0
		# Затухание считаем сами по inner/outer радиусу — так предсказуемее.
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		player.panning_strength = 1.0
		add_child(player)
		player.global_position = zone_position
		player.play()
		state["player"] = player


func _resolve_zone_position(data: Dictionary) -> Vector3:
	var fallback: Variant = data.get("position", Vector3.ZERO)
	var poi_name := str(data.get("poi", ""))
	if not poi_name.is_empty():
		var world: Variant = _find_world()
		if world != null and world.has_method("get_poi"):
			var poi_position: Vector3 = world.call("get_poi", StringName(poi_name))
			if poi_position != Vector3.ZERO:
				return poi_position + Vector3(0.0, float(data.get("height", 0.0)), 0.0)
	return fallback if typeof(fallback) == TYPE_VECTOR3 else Vector3.ZERO


## World может быть как родителем, так и соседним узлом (Main/World).
func _find_world() -> Variant:
	var parent := get_parent()
	if parent == null:
		return null
	var world: Variant = parent.get_node_or_null("World")
	if world != null:
		return world
	if parent.has_method("get_poi"):
		return parent
	return null


func _update_zones(delta: float) -> void:
	if _zone_state.is_empty():
		return
	var listener := _listener_position()
	var surface_origin := listener
	if _player != null and is_instance_valid(_player):
		surface_origin = _player.global_position
	var best_surface := SURFACE_DEFAULT
	var best_surface_gain := 0.51
	for id in _zone_state.keys():
		var state: Dictionary = _zone_state[id]
		var data: Dictionary = state.get("data", {})
		var zone_position: Vector3 = state.get("position", Vector3.ZERO)
		var inner := float(data.get("inner_radius", 3.0))
		var outer := float(data.get("outer_radius", 12.0))
		if inner >= outer:
			inner = outer * 0.5
		var distance := listener.distance_to(zone_position)
		var gain := 0.0
		if distance <= inner:
			gain = 1.0
		elif distance < outer:
			gain = 1.0 - (distance - inner) / maxf(outer - inner, 0.001)
		var player_variant: Variant = state.get("player", null)
		if player_variant != null and is_instance_valid(player_variant):
			var player := player_variant as AudioStreamPlayer3D
			var target_db := -80.0
			if gain > 0.01:
				var peak_db := float(data.get("volume_db", 0.0))
				target_db = peak_db + linear_to_db(clampf(gain, 0.001, 1.0))
			player.volume_db = lerpf(player.volume_db, target_db, clampf(delta * zone_fade_speed, 0.0, 1.0))
			if gain > 0.01 and not player.playing:
				player.play()
		var surface := str(data.get("surface", ""))
		if not surface.is_empty():
			var surface_distance := surface_origin.distance_to(zone_position)
			var surface_gain := 0.0
			if surface_distance <= inner:
				surface_gain = 1.0
			elif surface_distance < outer:
				surface_gain = 1.0 - (surface_distance - inner) / maxf(outer - inner, 0.001)
			if surface_gain > best_surface_gain:
				best_surface_gain = surface_gain
				best_surface = surface
	_apply_surface(best_surface)


func _apply_surface(surface: String) -> void:
	if surface == _surface_current:
		return
	_surface_current = surface
	if _audio != null and _audio.has_method("set_footstep_surface"):
		_audio.set_footstep_surface(surface)
	if verbose:
		print("[ambience] поверхность шагов: %s" % surface)


func _listener_position() -> Vector3:
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		return camera.global_position
	if _player != null and is_instance_valid(_player):
		return _player.global_position
	return Vector3.ZERO


# --- Дождь -------------------------------------------------------------------


func _update_rain(delta: float) -> void:
	if not rain_enabled or rain_variants.is_empty():
		return
	_rain_clock -= delta
	if _rain_clock > 0.0:
		return
	_rain_clock = maxf(rain_change_seconds + _rng.randf_range(-6.0, 6.0), 8.0)
	var next := _pick_rain_variant()
	if next == _rain_current:
		return
	if _audio.play_ambience(next, 2.5, rain_volume_db):
		_rain_current = next
		if verbose:
			print("[ambience] дождь: %s" % next)
	else:
		# Файла нет/битый: не спамим попытками каждый кадр, повторим позже.
		_rain_clock = 5.0


func _pick_rain_variant() -> String:
	if rain_variants.size() == 1:
		return rain_variants[0]
	var index := _rng.randi_range(0, rain_variants.size() - 1)
	var candidate := rain_variants[index]
	if candidate == _rain_current:
		candidate = rain_variants[(index + 1) % rain_variants.size()]
	return candidate


# --- Игрок -------------------------------------------------------------------


func _update_player_reference(delta: float) -> void:
	if _player != null and is_instance_valid(_player):
		return
	_search_clock -= delta
	if _search_clock > 0.0:
		return
	_search_clock = maxf(player_search_interval, 0.1)
	_find_player()


func _find_player() -> void:
	var candidate := get_tree().get_first_node_in_group("player")
	if candidate == null:
		return
	_player = candidate as Node3D
	if _player == null:
		return
	if auto_register_player and _audio != null and _audio.has_method("register_player"):
		_audio.register_player(_player)
	if verbose:
		print("[ambience] игрок подключён: %s" % _player.name)
