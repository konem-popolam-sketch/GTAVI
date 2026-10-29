extends Node3D
## t52: прогон одной катсцены headless и съёмка кадров для проверки постановки.
##
## Запуск headless (движок сам выйдет по --quit-after):
##   godot --headless --path . --quit-after 300 res://tests/t52_cutscene_run.tscn -- --cut=cut_box
## Кадры (нужно окно):
##   godot --path . res://tests/t52_cutscene_run.tscn -- --cut=cut_box --shots

@onready var stage: CutscenePlayer = $CutsceneStage
@onready var player: Player = $Player


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var cutscene_id := _arg_value("--cut=", "cut_box")
	if cutscene_id == "cut_box":
		_add_twin_box_prop()
	if OS.get_cmdline_user_args().has("--sfx-check"):
		_check_sfx_aliases()
		get_tree().quit(0)
		return
	if OS.get_cmdline_user_args().has("--shots"):
		await _run_shots(cutscene_id)
		return
	stage.step_executed.connect(_on_step_executed)
	var started := stage.start(cutscene_id, true)
	print("[t52] start(%s)=%s t=%.2f" % [cutscene_id, str(started), stage.get_time()])
	if OS.get_cmdline_user_args().has("--full"):
		await get_tree().create_timer(5.6).timeout
		print("[t52] full-run t=%.2f playing=%s" % [stage.get_time(), str(stage.is_playing())])
		get_tree().quit(0)


func _on_step_executed(cutscene_id: String, step_type: String, time: float) -> void:
	if step_type == "sfx":
		print("[t52] sfx step %s at t=%.2f (cutscene %s)" % [step_type, time, cutscene_id])


func _check_sfx_aliases() -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio == null or not audio.has_method("play_sfx"):
		push_error("[t52] AudioManager недоступен")
		return
	var legacy: Variant = audio.call("play_sfx", "gunshot")
	var modern: Variant = audio.call("play_sfx", "pistol_fire")
	var reload: Variant = audio.call("play_sfx", "gun_reload")
	var empty: Variant = audio.call("play_sfx", "gun_empty")
	print("[t52] sfx aliases: gunshot=%s pistol_fire=%s gun_reload=%s gun_empty=%s" % [
		str(legacy != null), str(modern != null), str(reload != null), str(empty != null)
	])
	if legacy == null or modern == null or reload == null or empty == null:
		push_error("[t52] SFX alias check FAIL")
	else:
		print("[t52] SFX ALIAS OK")


func _run_shots(cutscene_id: String) -> void:
	if DisplayServer.get_name() == "headless":
		push_error("[t52] --shots требует окно")
		get_tree().quit(1)
		return
	var shots_dir := ProjectSettings.globalize_path("res://docs/shots_t52")
	DirAccess.make_dir_recursive_absolute(shots_dir)
	if not stage.start(cutscene_id, true):
		push_error("[t52] не стартовала %s" % cutscene_id)
		get_tree().quit(1)
		return
	var times: Array[float] = [1.6, 6.0]
	if cutscene_id != "cut_box":
		times = [1.6, 8.0]
	var previous := 0.0
	for i in times.size():
		await get_tree().create_timer(times[i] - previous).timeout
		previous = times[i]
		var path := "%s/%s_%02d.png" % [shots_dir, cutscene_id, i + 1]
		await _capture_frame(path)
		print("[t52] кадр %s (t=%.2f, camera=%s)" % [
			path, stage.get_time(), str(stage.get_cutscene_camera().global_position)
		])
	stage.skip()
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0)


func _add_twin_box_prop() -> void:
	var box := MeshInstance3D.new()
	box.name = "TwinBoxProp"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.55, 0.35, 0.45)
	box.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.33, 0.2)
	material.roughness = 0.9
	box.material_override = material
	box.position = Vector3(6.2, 1.36, -25.1)
	add_child(box)


func _capture_frame(path: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error == OK:
		print("[t52] кадр сохранён: %s" % path)
	else:
		push_error("[t52] не удалось сохранить кадр: %s (%d)" % [path, error])


func _arg_value(prefix: String, fallback: String) -> String:
	for arg in OS.get_cmdline_user_args():
		var text := str(arg)
		if text.begins_with(prefix):
			return text.substr(prefix.length())
	return fallback
