class_name Car
extends VehicleBody3D
## Машина игрока: VehicleBody3D из примитивов.
##
## Ввод и камера живут в дочернем узле Controller (scripts/vehicles/car_controller.gd),
## сама машина отвечает только за физику и состояние «занята/свободна».
##
## ПУБЛИЧНЫЙ API:
##   enter(player: Node3D) -> bool   — посадить игрока (заодно отключает его управление)
##   exit(player = null) -> bool     — высадить игрока рядом с дверью
##   is_occupied() -> bool
##   get_velocity_kmh() -> float     — модуль скорости в км/ч
##   set_drive_input(throttle, steer, brake, handbrake)
##   get_engine_player() -> AudioStreamPlayer3D  — петля двигателя (t54)
##   has_engine_audio() -> bool; is_engine_audio_playing() -> bool
##   сигналы: entered(player), exited(player)
##
## Звук (t54): дверца — AudioManager.play_sfx("car_door", global_position);
## петля двигателя — собственный AudioStreamPlayer3D на шине SFX: тишина, пока
## машина свободна, при enter() fade-in 0.25 с, pitch 0.85→1.15 и громкость
## −6→−2 dB от скорости, при exit() fade-out 0.3 с и stop(). Если AudioManager
## ещё не готов — ждём его сигнал audio_ready().
##
## Числа: масса 1200 кг, центр тяжести на 0.25 м ниже центра кузова,
## максимум 108 км/ч (30 м/с), руль 34°, привод на задние колёса.

signal entered(player: Node3D)
signal exited(player: Node3D)

## Сила тяги на заднюю ось (Н). 2600 Н на 1200 кг даёт ≈2.2 м/с² — город 350 м
## проезжается за ~15 с даже без разгона до максимума.
@export var max_engine_force: float = 2600.0
@export var brake_force: float = 22.0
@export var handbrake_force: float = 45.0
@export var max_speed_kmh: float = 108.0
@export_range(5.0, 60.0, 0.5) var steering_max_deg: float = 34.0
@export var steering_speed: float = 2.6
@export var steering_return_speed: float = 6.0
## Сопротивление качению: гасит скорость, когда газ отпущен.
@export var rolling_resistance: float = 0.35
## SFX (если AudioManager и файлы уже есть — иначе просто тихо).
@export var sfx_enabled: bool = true

@export_group("Звук двигателя (t54)")
## Петля двигателя: тишина, пока машина свободна; при enter — fade-in.
@export var engine_audio_enabled: bool = true
@export var engine_fade_in: float = 0.25
@export var engine_fade_out: float = 0.3
@export var engine_idle_pitch: float = 0.85
@export var engine_max_pitch: float = 1.15
@export var engine_idle_volume_db: float = -6.0
@export var engine_max_volume_db: float = -2.0
## Скорость, на которой pitch/громкость выходят на максимум.
@export var engine_max_kmh: float = 108.0

## Тишина для фейда: linear_to_db(0) = -inf, поэтому гасим в -60 dB.
const ENGINE_SILENT_DB := -60.0
## Автолоад на выходе глушит все плееры этой группы (иначе утечка playback'ов).
const LOOP_PLAYER_GROUP := "audio_loop_player"

var driver: Node3D = null

var _throttle: float = 0.0
var _steer_input: float = 0.0
var _brake_input: float = 0.0
var _handbrake: bool = false

var _engine_player: AudioStreamPlayer3D = null
var _engine_audio_waiting: bool = false
var _engine_fade: float = 0.0
var _engine_fade_target: float = 0.0

@onready var controller: Node = get_node_or_null("Controller")
@onready var chase_camera: Camera3D = find_child("ChaseCamera", true, false) as Camera3D
@onready var seat: Node3D = get_node_or_null("Seat")
@onready var _engine_sfx_position: Node3D = self


func _ready() -> void:
	add_to_group("vehicle")
	# Центр тяжести ниже кузова — иначе машина кивает и переворачивается.
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, -0.25, 0.0)
	can_sleep = false
	if controller == null:
		push_warning("[car] нет узла Controller — машину можно толкать, но не водить")
	if chase_camera != null:
		chase_camera.current = false
	_setup_engine_audio()


func _physics_process(delta: float) -> void:
	var speed_kmh: float = absf(get_velocity_kmh())
	var target_steer: float = _steer_input * deg_to_rad(steering_max_deg)
	var steer_rate: float = steering_speed
	if absf(_steer_input) < 0.01:
		steer_rate = steering_return_speed
	steering = move_toward(steering, target_steer, steer_rate * delta)

	var engine: float = _throttle * max_engine_force
	if speed_kmh >= max_speed_kmh:
		engine = 0.0
	if _throttle < 0.01 and _brake_input < 0.01 and not _handbrake:
		# Свободный накат: гасим скорость плавно, но не «якорем».
		linear_velocity = linear_velocity * (1.0 - clampf(rolling_resistance * delta, 0.0, 0.9))
	engine_force = engine

	var braking: float = brake_force * clampf(_brake_input, 0.0, 1.0)
	if _handbrake:
		braking = maxf(braking, handbrake_force)
	brake = braking

	# Петля двигателя живёт и после выхода, пока идёт fade-out.
	if _engine_player != null and _engine_player.playing:
		var audio_speed: float = speed_kmh if driver != null else 0.0
		_update_engine_audio(audio_speed, delta)


# --- Публичный API -----------------------------------------------------------


func enter(player: Node3D) -> bool:
	if is_occupied() or player == null:
		return false
	driver = player
	if controller != null and controller.has_method("attach"):
		controller.call("attach", player)
	_play_sfx("car_door")
	_start_engine_audio()
	entered.emit(player)
	return true


func exit(player: Node3D = null) -> bool:
	if not is_occupied():
		return false
	var who: Node3D = player if player != null else driver
	if controller != null and controller.has_method("detach"):
		controller.call("detach", who)
	driver = null
	# Заглушить: без водителя машина не должна катиться.
	engine_force = 0.0
	brake = brake_force
	_play_sfx("car_door")
	_stop_engine_audio()
	exited.emit(who)
	return true


func is_occupied() -> bool:
	return driver != null


func get_velocity_kmh() -> float:
	return linear_velocity.length() * 3.6


func set_drive_input(throttle: float, steer: float, brake_input: float, handbrake: bool) -> void:
	_throttle = clampf(throttle, -1.0, 1.0)
	_steer_input = clampf(steer, -1.0, 1.0)
	_brake_input = clampf(brake_input, 0.0, 1.0)
	_handbrake = handbrake


func release_drive_input() -> void:
	set_drive_input(0.0, 0.0, 0.0, false)


# --- Внутреннее --------------------------------------------------------------


# --- Звук двигателя (t54) ----------------------------------------------------


## Создаёт AudioStreamPlayer3D ребёнком машины. Поток берём через AudioManager
## (он копирует ресурс и включает loop_mode). Если автолоад ещё не готов —
## ждём audio_ready и повторяем: при загрузке сохранения это может случиться позже.
func _setup_engine_audio() -> void:
	if not engine_audio_enabled or not sfx_enabled:
		return
	if _engine_player != null and is_instance_valid(_engine_player):
		return
	var audio: Variant = get_node_or_null("/root/AudioManager")
	if audio == null:
		return
	if audio.has_method("is_ready") and not bool(audio.call("is_ready")):
		if not _engine_audio_waiting:
			_engine_audio_waiting = true
			if audio.has_signal("audio_ready"):
				audio.connect("audio_ready", _setup_engine_audio)
		return
	_engine_audio_waiting = false
	var stream: AudioStream = null
	if audio.has_method("get_stream"):
		stream = audio.call("get_stream", "car_engine_loop", "sfx", true)
	if stream == null:
		push_warning("[car] нет car_engine_loop.wav — двигатель будет беззвучным")
		return
	_engine_player = AudioStreamPlayer3D.new()
	_engine_player.name = "EngineAudio"
	_engine_player.stream = stream
	# Шина SFX: ползунок эффектов должен регулировать и двигатель.
	_engine_player.bus = "SFX"
	_engine_player.position = Vector3(0.0, 0.75, 1.1)
	_engine_player.unit_size = 6.0
	_engine_player.max_distance = 45.0
	_engine_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_engine_player.volume_db = ENGINE_SILENT_DB
	add_child(_engine_player)
	_engine_player.add_to_group(LOOP_PLAYER_GROUP)
	# Машина уже занята (audio_ready пришёл после посадки) — включаемся сразу.
	if is_occupied():
		_start_engine_audio()


func _start_engine_audio() -> void:
	if _engine_player == null or not is_instance_valid(_engine_player):
		_setup_engine_audio()
	if _engine_player == null or not is_instance_valid(_engine_player):
		return
	_engine_fade = 0.0
	_engine_fade_target = 1.0
	_engine_player.pitch_scale = engine_idle_pitch
	_engine_player.volume_db = ENGINE_SILENT_DB
	if not _engine_player.playing:
		_engine_player.play()


## Не останавливаем сразу: fade-out ведёт _update_engine_audio, stop — по нулю.
func _stop_engine_audio() -> void:
	_engine_fade_target = 0.0


## Pitch 0.85 (холостой) → 1.15 (108 км/ч), громкость −6 → −2 dB, плюс fade.
func _update_engine_audio(speed_kmh: float, delta: float) -> void:
	if _engine_player == null or not is_instance_valid(_engine_player):
		return
	var ratio := clampf(speed_kmh / maxf(engine_max_kmh, 1.0), 0.0, 1.0)
	var fade_speed := 1.0 / maxf(engine_fade_out, 0.02)
	if _engine_fade_target > _engine_fade:
		fade_speed = 1.0 / maxf(engine_fade_in, 0.02)
	_engine_fade = move_toward(_engine_fade, _engine_fade_target, fade_speed * delta)
	_engine_player.pitch_scale = lerpf(engine_idle_pitch, engine_max_pitch, ratio)
	var base_db := lerpf(engine_idle_volume_db, engine_max_volume_db, ratio)
	_engine_player.volume_db = base_db + linear_to_db(maxf(_engine_fade, 0.0001))
	if _engine_fade <= 0.001 and _engine_fade_target <= 0.0:
		_engine_player.stop()
		_engine_player.volume_db = ENGINE_SILENT_DB


## Плеер двигателя (для тестов/отладки); null, пока звук не подключён.
func get_engine_player() -> AudioStreamPlayer3D:
	return _engine_player


func has_engine_audio() -> bool:
	return _engine_player != null and is_instance_valid(_engine_player)


func is_engine_audio_playing() -> bool:
	return has_engine_audio() and _engine_player.playing


func _exit_tree() -> void:
	if _engine_player != null and is_instance_valid(_engine_player):
		_engine_player.stop()
		_engine_player.stream = null


# --- Разовые эффекты ---------------------------------------------------------


## Дверца всегда в 3D-позиции машины, иначе звук «плавает» в центре мира.
func _play_sfx(sound_name: String) -> void:
	if not sfx_enabled:
		return
	var audio: Node = get_node_or_null("/root/AudioManager")
	if audio == null or not audio.has_method("play_sfx"):
		return
	audio.call("play_sfx", sound_name, global_position, 0.0)
