extends Node3D
## Смоук звука машины (t54). Запуск:
##   & .\tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . \
##       tests/car_audio_smoke.tscn --log-file tools/car_audio_smoke.log
##
## Проверяет петлю двигателя и дверцу:
##   • пока машина свободна — EngineAudio молчит;
##   • после enter() петля играет на шине SFX, громкость −6 dB, pitch 0.85;
##   • на 108 км/ч pitch 1.15 (±допуск), громкость ближе к −2 dB;
##   • после exit() через 0.4 с playing == false;
##   • если AudioManager ещё не готов — машина не падает, плеер не включает,
##     а после сигнала audio_ready() петля создаётся и играет.
##
## Печатает "CAR AUDIO SMOKE OK (N проверок)" и выходит с кодом 0.

const MAIN_SCENE := "res://scenes/main.tscn"
const CAR_SCENE := "res://scenes/vehicles/car.tscn"
const ROAD_POINT := Vector3(-40.0, 0.8, -110.0)

const ENGINE_IDLE_PITCH := 0.85
const ENGINE_MAX_PITCH := 1.15
const ENGINE_IDLE_DB := -6.0
const ENGINE_MAX_DB := -2.0

var _passed: int = 0
var _failed: int = 0
var _lines: PackedStringArray = PackedStringArray()

var _main: Node3D = null
var _player: Node3D = null
var _car: VehicleBody3D = null
var _audio: Node = null


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _boot()

	# --- 0. Автолоад ---
	_check("AudioManager найден", _audio != null)
	_check("AudioManager готов", _audio != null and bool(_audio.call("is_ready")))

	# --- 1. До посадки тишина ---
	var engine: AudioStreamPlayer3D = _engine_of(_car)
	_check("машина создала EngineAudio", engine != null)
	_check("до посадки двигатель молчит", engine == null or not engine.playing)

	# --- 2. Посадка: play + шина SFX + холостой ход ---
	var entered: bool = bool(_car.call("enter", _player))
	await _wait_time(0.4)
	engine = _engine_of(_car)
	_check("enter() вернул true", entered)
	_check("после enter двигатель играет", engine != null and engine.playing)
	_check("петля на шине SFX", engine != null and str(engine.bus) == "SFX")
	_check(
		"pitch на холостом ходу ≈ %.2f (%.3f)" % [ENGINE_IDLE_PITCH, _pitch(engine)],
		engine != null and absf(_pitch(engine) - ENGINE_IDLE_PITCH) < 0.03
	)
	_check(
		"громкость холостого хода ≈ %.1f dB (%.1f)" % [ENGINE_IDLE_DB, _volume(engine)],
		engine != null and _volume(engine) > -10.0 and _volume(engine) < -3.0
	)
	_check("звук двигателя 3D (AudioStreamPlayer3D)", engine is AudioStreamPlayer3D)

	# --- 3. Разгон: pitch и громкость растут ---
	# Толкаем машину вперёд (её +Z) со скоростью ~108 км/ч.
	_car.linear_velocity = _car.global_transform.basis.z * 30.0
	await _wait_physics(3)
	engine = _engine_of(_car)
	var speed_kmh: float = float(_car.call("get_velocity_kmh"))
	_check(
		"pitch растёт со скоростью (%.1f км/ч → %.3f)" % [speed_kmh, _pitch(engine)],
		engine != null and _pitch(engine) > ENGINE_IDLE_PITCH + 0.12
	)
	_check(
		"pitch у максимума ≈ %.2f (%.3f)" % [ENGINE_MAX_PITCH, _pitch(engine)],
		engine != null and _pitch(engine) <= ENGINE_MAX_PITCH + 0.01
	)
	_check(
		"громкость на скорости ближе к %.1f dB (%.1f)" % [ENGINE_MAX_DB, _volume(engine)],
		engine != null and _volume(engine) > -5.0
	)

	# --- 4. Выход: fade-out и stop ---
	var exited: bool = bool(_car.call("exit"))
	await _wait_time(0.45)
	engine = _engine_of(_car)
	_check("exit() вернул true", exited)
	_check("через 0.45 с после exit двигатель остановлен", engine != null and not engine.playing)
	_check("после exit громкость в тишине", engine != null and _volume(engine) <= -40.0)

	# --- 5. AudioManager не готов: ждём, не падаем ---
	await _check_not_ready_guard()

	# Чисто выходим: гасим зоны окружения и автолоад, чтобы не оставить
	# playback'и на выходе (как в 600-кадровом прогоне).
	await _wait_physics(4)
	get_tree().call_group("audio_ambience", "shutdown")
	if _audio != null and _audio.has_method("shutdown"):
		_audio.call("shutdown")
	await _wait_physics(6)
	_finish()


func _check_not_ready_guard() -> void:
	if _audio == null:
		_check("без AudioManager машина не падает", false)
		return
	# Симулируем «автолоад ещё не инициализирован» так же, как это бывает
	# при загрузке сохранения: is_ready() == false, audio_ready ещё не пришёл.
	_audio.set("_initialized", false)
	var car_scene: PackedScene = load(CAR_SCENE)
	var car2: Node3D = car_scene.instantiate() as Node3D
	_main.add_child(car2)
	await _wait_physics(3)
	_check("без готового AudioManager плеер не создан", _engine_of(car2) == null)

	var dummy := Node3D.new()
	dummy.name = "DummyDriver"
	_main.add_child(dummy)
	var ok_enter: bool = bool(car2.call("enter", dummy))
	await _wait_physics(3)
	_check("enter() без AudioManager не падает", ok_enter)
	_check("до audio_ready двигатель молчит", _engine_of(car2) == null)

	_audio.set("_initialized", true)
	_audio.emit_signal("audio_ready")
	await _wait_time(0.45)
	var engine2: AudioStreamPlayer3D = _engine_of(car2)
	_check("после audio_ready плеер создан", engine2 != null)
	_check("после audio_ready двигатель играет", engine2 != null and engine2.playing)
	_check("петля второй машины тоже на SFX", engine2 != null and str(engine2.bus) == "SFX")

	car2.call("exit")
	await _wait_time(0.45)
	_check("вторая машина глушится после exit", engine2 != null and not engine2.playing)


# --- Инфраструктура -----------------------------------------------------------


func _boot() -> void:
	_audio = get_node_or_null("/root/AudioManager")
	var main_scene: PackedScene = load(MAIN_SCENE)
	_main = main_scene.instantiate() as Node3D
	add_child(_main)
	await _wait_physics(8)
	_player = _main.get_node_or_null("Player") as Node3D
	if _main.has_method("start_fresh"):
		_main.call("start_fresh")
	await _wait_physics(8)

	var car_scene: PackedScene = load(CAR_SCENE)
	_car = car_scene.instantiate() as VehicleBody3D
	_main.add_child(_car)
	await _wait_physics(3)
	_car.global_position = ROAD_POINT
	_car.linear_velocity = Vector3.ZERO
	await _wait_physics(30)


func _engine_of(car: Node) -> AudioStreamPlayer3D:
	if car == null or not car.is_inside_tree():
		return null
	if not car.has_method("get_engine_player"):
		return null
	return car.call("get_engine_player") as AudioStreamPlayer3D


func _pitch(player: AudioStreamPlayer3D) -> float:
	return player.pitch_scale if player != null else 0.0


func _volume(player: AudioStreamPlayer3D) -> float:
	return player.volume_db if player != null else -80.0


func _wait_physics(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame


func _wait_time(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _check(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		_lines.append("  ok   " + label)
	else:
		_failed += 1
		_lines.append("  FAIL " + label)


func _finish() -> void:
	print("[car_audio_smoke] --- результаты ---")
	for line in _lines:
		print(line)
	if _failed == 0:
		print("CAR AUDIO SMOKE OK (%d проверок)" % _passed)
		get_tree().quit(0)
	else:
		print("CAR AUDIO SMOKE FAILED (%d провалено из %d)" % [_failed, _passed + _failed])
		get_tree().quit(1)
