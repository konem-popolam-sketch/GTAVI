extends SceneTree
## Смоук-тест людей (t15): humanoid, npc, player.
## Запуск: tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . --script tests/people_smoke.gd
## Успех: строка "T15 PEOPLE SMOKE OK" и код возврата 0.

var _failures: Array[String] = []
var _checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await _test_humanoid()
	await _test_locomotion()
	await _test_npc()
	await _test_player()
	_report()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
		print("[FAIL] ", message)


func _test_humanoid() -> void:
	var scene: PackedScene = load("res://scenes/actors/humanoid.tscn")
	_check(scene != null, "humanoid.tscn не загрузился")
	if scene == null:
		return
	var humanoid: Node = scene.instantiate()
	root.add_child(humanoid)
	await process_frame
	await process_frame

	_check(humanoid is MeshInstance3D, "корень humanoid должен быть MeshInstance3D")
	_check(humanoid.get_part_count() >= 20, "сегментов тела меньше 20: %d" % humanoid.get_part_count())
	_check(is_equal_approx(humanoid.get_hip_height(), 0.92), "высота таза %.3f" % humanoid.get_hip_height())
	for bone_name in ["Spine", "Chest", "Neck", "Head", "ThighL", "ShinL", "FootL", "ThighR",
			"ShinR", "FootR", "UpperArmL", "ForearmL", "HandL", "UpperArmR", "ForearmR", "HandR"]:
		_check(humanoid.find_child(bone_name, true, false) != null, "нет кости %s" % bone_name)
	var anim: AnimationPlayer = humanoid.get_animation_player()
	_check(anim != null, "нет AnimationPlayer")
	if anim != null:
		_check(anim.has_animation("idle"), "нет анимации idle")
		_check(anim.has_animation("walk"), "нет анимации walk")
		_check(anim.has_animation("run"), "нет анимации run")
		_check(anim.is_playing(), "AnimationPlayer не играет")
		_check(humanoid.get_current_animation() == "idle", "старт не с idle")
	# материал корня должен быть StandardMaterial3D — его дублирует player.gd для fade
	var root_mat := (humanoid as MeshInstance3D).get_surface_override_material(0)
	_check(root_mat is StandardMaterial3D, "у корня нет StandardMaterial3D для fade")

	# палитры: рост и цвет меняются
	var hips_height_before: float = humanoid.get_hip_height()
	humanoid.apply_skin("mila")
	_check(humanoid.skin_preset == "mila", "палитра mila не применилась")
	_check(not is_equal_approx(humanoid.get_hip_height(), hips_height_before), "рост не изменился по палитре")
	humanoid.apply_skin("unknown-skin")
	_check(humanoid.skin_preset == "npc", "неизвестная палитра не откатилась в npc")
	_check(humanoid.get_skin_names().size() >= 4, "палитр меньше 4")

	humanoid.queue_free()
	await process_frame


func _test_locomotion() -> void:
	var scene: PackedScene = load("res://scenes/actors/humanoid.tscn")
	var body := CharacterBody3D.new()
	root.add_child(body)
	var humanoid: Node = scene.instantiate()
	humanoid.name = "Body"
	body.add_child(humanoid)
	await process_frame
	await process_frame

	body.velocity = Vector3(0.0, 0.0, 4.0)
	await process_frame
	await process_frame
	_check(humanoid.get_current_animation() == "walk", "при 4 м/с ждали walk, а %s" % humanoid.get_current_animation())

	body.velocity = Vector3(0.0, 0.0, 7.0)
	await process_frame
	await process_frame
	_check(humanoid.get_current_animation() == "run", "при 7 м/с ждали run, а %s" % humanoid.get_current_animation())

	body.velocity = Vector3.ZERO
	await process_frame
	await process_frame
	_check(humanoid.get_current_animation() == "idle", "стоя ждали idle, а %s" % humanoid.get_current_animation())

	body.queue_free()
	await process_frame


func _test_npc() -> void:
	var scene: PackedScene = load("res://scenes/actors/npc.tscn")
	var npc: Node = scene.instantiate()
	npc.npc_id = "mila"
	npc.display_name = "Мила"
	npc.dialogue_id = "mila"
	npc.skin = "mila"
	root.add_child(npc)
	await process_frame
	await process_frame
	_check(npc.is_in_group("npc"), "NPC не в группе npc")
	_check(npc.is_in_group("interactable"), "NPC не в группе interactable")
	_check(npc.get_meta("interactable", false) == true, "нет метаданных interactable")
	_check(npc.get_dialogue_id() == "mila", "dialogue_id сломан")
	var body: Node = npc.get_node_or_null("Body")
	_check(body is MeshInstance3D, "Body у NPC не MeshInstance3D")
	_check(body != null and body.skin_preset == "mila", "скин NPC не применился")
	var label: Label3D = npc.get_node_or_null("NameLabel")
	_check(label != null and label.text == "Мила", "подпись NPC не обновилась")
	_check(label != null and label.position.y >= 2.0, "подпись ниже 2 м")
	var highlight: OmniLight3D = npc.get_node_or_null("Highlight")
	_check(highlight != null and highlight.omni_range <= 3.2, "подсветка NPC слишком широкая (ореол)")
	var area: Area3D = npc.get_node_or_null("DetectArea")
	_check(area != null and area.collision_mask == 1, "DetectArea без маски игрока")
	_check(npc.has_method("interact") and npc.has_method("set_highlight"), "потерян публичный API NPC")
	# interact без подписчиков не должен падать
	npc.interact()
	npc.set_highlight(false)
	npc.queue_free()
	await process_frame


func _test_player() -> void:
	var scene: PackedScene = load("res://scenes/player/player.tscn")
	var player: Node = scene.instantiate()
	root.add_child(player)
	await process_frame
	await process_frame
	var body: Node = player.get_node_or_null("Body")
	_check(body is MeshInstance3D, "Body игрока не MeshInstance3D")
	_check(body != null and body.has_method("apply_skin"), "Body игрока — не Humanoid")
	_check(body != null and body.skin_preset == "player", "скин игрока не применился")
	var spring: SpringArm3D = player.get_node_or_null("SpringArm3D")
	_check(spring != null, "нет SpringArm3D")
	var camera: Camera3D = player.get_node_or_null("SpringArm3D/Camera3D")
	_check(camera != null and camera.current, "камера игрока не current")
	var interactor: Node = player.get_node_or_null("SpringArm3D/Camera3D/Interactor")
	_check(interactor != null and interactor.collision_mask == 1, "интерактор сломан")
	var fade_mat := (body as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D
	_check(fade_mat != null, "player.gd не сможет гасить меш: нет override-материала")
	_check(player.get_camera_distance() >= 0.0, "get_camera_distance упал")
	player.queue_free()
	await process_frame


func _report() -> void:
	if _failures.is_empty():
		print("T15 PEOPLE SMOKE OK (%d проверок)" % _checks)
		quit(0)
		return
	print("T15 PEOPLE SMOKE FAILED: %d из %d" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	quit(1)
