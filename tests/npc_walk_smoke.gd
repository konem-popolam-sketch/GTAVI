extends Node3D
## Смоук живых NPC: ходьба по маршруту, паузы, остановка на диалог,
## возобновление, поиск ходящего NPC интерактором, реакция Тимура на игрока.
## Запуск: godot --headless --path . --quit-after 2400 res://tests/npc_walk_smoke.tscn
## Успех: строка "NPC WALK SMOKE OK" и 10 пройденных проверок.

const NPC_SCENE := "res://scenes/actors/npc.tscn"
const PLAYER_SCENE := "res://scenes/player/player.tscn"

var checks_passed: int = 0
var failures: Array[String] = []
var walker_npc: NPC
var static_npc: NPC
var timur_npc: NPC
var player: Player
var waypoint_count: int = 0
var pause_samples: Array[float] = []


func _ready() -> void:
	print("=== NPC WALK SMOKE START ===")
	await get_tree().process_frame
	walker_npc = _spawn_npc("kostya", "kostya", Vector3(0.0, 0.0, 0.0))
	static_npc = _spawn_npc("mila", "mila", Vector3(9.0, 0.0, 0.0))
	timur_npc = _spawn_npc("timur", "timur", Vector3(18.0, 0.0, 0.0))
	player = _spawn_player(Vector3(0.0, 0.1, -6.0))
	await get_tree().physics_frame
	await get_tree().physics_frame

	var walker := walker_npc.get_walker()
	_check(walker != null and walker_npc.is_walking(),
		"1. NPC с walk_enabled должен ходить (Костя)")
	if walker != null:
		walker.waypoint_reached.connect(_on_waypoint_reached)

	# Стартовая пауза в первой точке не входит в окно замера: ждём, пока NPC
	# тронется, и только потом считаем пройденные точки за 6 секунд.
	await _wait_until_not_waiting(walker)
	waypoint_count = 0
	var start_position := walker_npc.global_position
	var static_start := static_npc.global_position
	await _wait_seconds(6.0)
	var walked := _flat_distance(start_position, walker_npc.global_position)
	_check(waypoint_count >= 2,
		"2. За 6 с пройдено точек: %d (ожидалось ≥2)" % waypoint_count)
	var area_offset := walker_npc.get_node_or_null("DetectArea") as Area3D
	var area_follows := area_offset != null and _flat_distance(
		area_offset.global_position, walker_npc.global_position + Vector3(0, 1, 0)
	) < 0.05
	_check(walked >= 1.0 and area_follows,
		"3. Пройдено %.2f м, Area3D следует за NPC: %s" % [walked, area_follows])
	_check(_flat_distance(static_start, static_npc.global_position) < 0.05,
		"4. NPC без флага стоит на месте (Мила)")

	await _wait_until_not_waiting(walker)
	var before_dialogue := walker_npc.global_position
	var started := DialogueManager.start("kostya", walker_npc)
	await _wait_seconds(0.8)
	var frozen := _flat_distance(before_dialogue, walker_npc.global_position)
	_check(started and frozen < 0.05,
		"5. Диалог с ходящим NPC стартует и NPC стоит (сдвиг %.3f м)" % frozen)
	DialogueManager.close()
	await _wait_seconds(1.0)
	var resumed := _flat_distance(before_dialogue, walker_npc.global_position)
	_check(resumed > 0.1, "6. После диалога NPC продолжил движение (%.2f м)" % resumed)

	var pause_ok := false
	for pause_value in pause_samples:
		if pause_value >= 1.9 and pause_value <= 6.1:
			pause_ok = true
			break
	_check(pause_ok, "7. Пауза в точке 2–6 с (замеры: %s)" % str(pause_samples))

	await _wait_until_not_waiting(walker)
	var api_position := walker_npc.global_position
	walker_npc.set_walking(false)
	await _wait_seconds(0.5)
	var stopped := _flat_distance(api_position, walker_npc.global_position)
	walker_npc.set_walking(true)
	await _wait_seconds(0.7)
	var resumed_api := _flat_distance(api_position, walker_npc.global_position)
	_check(stopped < 0.05 and resumed_api > 0.1 and walker_npc.is_walking(),
		"8. set_walking(false/true): стоп %.3f м, старт %.2f м" % [stopped, resumed_api])

	await _wait_seconds(0.4)
	player.global_position = walker_npc.global_position + Vector3(0.0, 0.1, 2.5)
	player.rotation.y = 0.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	var interactor := player.get_interactor()
	var target: Node = interactor.get_current_target() if interactor != null else null
	_check(target == walker_npc,
		"9. Интерактор нашёл ходящего NPC с 2.5 м (target=%s)" % (
			target.name if target != null else "<null>"
		))

	var timur_walker := timur_npc.get_walker()
	player.global_position = timur_npc.global_position + Vector3(0.0, 0.1, 2.0)
	await _wait_seconds(0.4)
	var reacts := timur_walker != null and timur_walker.is_reacting_to_player() \
		and timur_walker.get_velocity().length() < 0.01
	_check(reacts, "10. Тимур останавливается и смотрит на игрока в радиусе 4 м")

	print("[t36] проверок пройдено: %d, провалов: %d" % [checks_passed, failures.size()])
	if failures.is_empty():
		print("NPC WALK SMOKE OK")
		get_tree().quit(0)
	else:
		for failure in failures:
			print("FAIL: %s" % failure)
		push_error("NPC WALK SMOKE FAILED: %d" % failures.size())
		get_tree().quit(1)


func _spawn_npc(npc_id: String, dialogue_id: String, position: Vector3) -> NPC:
	var npc := (load(NPC_SCENE) as PackedScene).instantiate() as NPC
	npc.npc_id = npc_id
	npc.display_name = npc_id.capitalize()
	npc.dialogue_id = dialogue_id
	npc.position = position
	add_child(npc)
	return npc


func _spawn_player(position: Vector3) -> Player:
	var instance := (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
	instance.position = position
	add_child(instance)
	instance.set_physics_process(false)
	return instance


func _on_waypoint_reached(_index: int) -> void:
	waypoint_count += 1
	var walker := walker_npc.get_walker()
	if walker != null:
		pause_samples.append(walker.get_pause_remaining())


func _wait_seconds(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _wait_until_not_waiting(walker: NPCWalker) -> void:
	var deadline := Time.get_ticks_msec() + 7000
	while walker != null and walker.is_waiting() and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame


func _flat_distance(a: Vector3, b: Vector3) -> float:
	var delta := a - b
	delta.y = 0.0
	return delta.length()


func _check(condition: bool, description: String) -> void:
	if condition:
		checks_passed += 1
		print("[t36] OK  %s" % description)
	else:
		failures.append(description)
		print("[t36] FAIL %s" % description)
