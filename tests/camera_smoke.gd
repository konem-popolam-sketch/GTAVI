extends Node
## T19 camera smoke: камера не проваливается под пол, SpringArm не схлопывается
## у стены, интерактор находит NPC Милу. Временный сценарный тест (в tests/).

const BLOCK_SCENE := "res://scenes/world/block.tscn"
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const MIN_CAMERA_Y := 0.35
const MIN_ARM_LENGTH := 1.2

var failures: Array[String] = []
var player: Player
var npc: Node3D
var camera: Camera3D
var interactor: Interactor


func _ready() -> void:
	print("=== T19 CAMERA SMOKE START ===")
	await get_tree().process_frame

	add_child((load(BLOCK_SCENE) as PackedScene).instantiate())

	player = (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
	player.position = Vector3(-5.8, 0.1, -8.5)
	player.rotation.y = 0.0
	add_child(player)

	# Простой интерактивный дубль Милы: не зависит от боевого npc.tscn,
	# который в этот момент может править другой специалист.
	npc = _make_interactable_npc(Vector3(-5.8, 0.0, -10.6), "Мила")
	add_child(npc)

	camera = player.get_camera()
	interactor = player.get_interactor()

	# 1. Открытое место, камера в покое.
	await _wait_physics_frames(60)
	_report("flat")
	_check_floor_and_length("flat")
	_check_target("flat")

	# 2. Спина к стене: синтетическая стенка в 1.2 м за игроком. Старый SpringArm
	#    схлопывался до ~1.05, теперь длина не должна опускаться ниже 1.2.
	var wall := _make_wall(Vector3(-5.8, 1.5, -7.3))
	await _wait_physics_frames(60)
	_report("wall")
	_check_floor_and_length("wall")
	# Цель в этой фазе не проверяем: синтетическая стена стоит между камерой и
	# Милой, интерактор физически не должен видеть NPC сквозь неё.
	wall.queue_free()
	await _wait_physics_frames(10)

	# 3. Наклон вниз до текущего предела (+40°): камера не должна уйти под пол.
	player._pitch = deg_to_rad(player.max_pitch_degrees)
	player.spring_arm.rotation.x = player._pitch
	await _wait_physics_frames(60)
	_report("down")
	_check_floor_and_length("down")

	if failures.is_empty():
		print("T19 CAMERA SMOKE OK: flat=%.3f/%.3f wall=%.3f down_camera_y=%.3f" % [
			_last_flat_camera_y, _last_flat_length, _last_wall_length, camera.global_position.y
		])
		get_tree().quit(0)
	else:
		for failure in failures:
			print("T19 CAMERA SMOKE FAIL: %s" % failure)
		push_error("T19 CAMERA SMOKE FAILED: %d" % failures.size())
		get_tree().quit(1)


var _last_flat_camera_y := 0.0
var _last_flat_length := 0.0
var _last_wall_length := 0.0


func _wait_physics_frames(count: int) -> void:
	for frame in count:
		await get_tree().physics_frame


func _report(phase: String) -> void:
	var target := interactor.get_current_target() if interactor != null else null
	var target_name := "<null>"
	if target != null:
		if target.has_meta("display_name"):
			target_name = str(target.get_meta("display_name"))
		else:
			target_name = target.name
	var camera_y := camera.global_position.y
	var arm_length := player.get_camera_distance()
	if phase == "flat":
		_last_flat_camera_y = camera_y
		_last_flat_length = arm_length
	elif phase == "wall":
		_last_wall_length = arm_length
	print("[t19] %s: feet_y=%.3f camera_y=%.3f hit_length=%.3f pitch_deg=%.2f target=%s" % [
		phase,
		player.global_position.y,
		camera_y,
		arm_length,
		rad_to_deg(player.spring_arm.rotation.x),
		target_name,
	])
	print("[t19] %s: interactor ray length=%.2f camera_to_npc=%.2f" % [
		phase,
		absf(interactor.target_position.z) if interactor != null else 0.0,
		camera.global_position.distance_to(npc.global_position),
	])


func _check_floor_and_length(phase: String) -> void:
	var camera_y := camera.global_position.y
	var feet_y := player.global_position.y
	var arm_length := player.get_camera_distance()
	_expect(camera_y >= MIN_CAMERA_Y, "%s: камера ниже %.2f м (y=%.3f)" % [
		phase, MIN_CAMERA_Y, camera_y
	])
	_expect(camera_y >= feet_y + MIN_CAMERA_Y - 0.001,
		"%s: камера ниже пола+%.2f (y=%.3f, feet=%.3f)" % [
			phase, MIN_CAMERA_Y, camera_y, feet_y
		])
	_expect(arm_length >= MIN_ARM_LENGTH, "%s: SpringArm короче %.2f м (%.3f)" % [
		phase, MIN_ARM_LENGTH, arm_length
	])


func _check_target(phase: String) -> void:
	var target := interactor.get_current_target() if interactor != null else null
	_expect(target != null, "%s: интерактор не нашёл Милу" % phase)


func _make_interactable_npc(position: Vector3, display_name: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "MilaDummy"
	body.position = position
	body.set_meta("interactable", true)
	body.set_meta("display_name", display_name)
	var shape_node := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	shape_node.shape = capsule
	shape_node.position.y = 0.9
	body.add_child(shape_node)
	var mesh_node := MeshInstance3D.new()
	var capsule_mesh := CapsuleMesh.new()
	capsule_mesh.radius = 0.4
	capsule_mesh.height = 1.8
	mesh_node.mesh = capsule_mesh
	mesh_node.position.y = 0.9
	body.add_child(mesh_node)
	return body


func _make_wall(position: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.name = "SmokeWall"
	wall.position = position
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 3.0, 0.3)
	shape_node.shape = box
	wall.add_child(shape_node)
	add_child(wall)
	return wall


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
