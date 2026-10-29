class_name CutscenePlayer
extends Node
## CutscenePlayer — проигрыватель катсцен «Ночной смены».
##
## Узел-инстанс scenes/game/cutscene_stage.tscn под Main: держит отдельную
## CutsceneCamera и собственный CanvasLayer (затемнение, субтитры, титр).
## Камера игрока не пересоздаётся — на время сцены она просто перестаёт быть
## current, ввод игрока выключен.
##
## Почему узел, а не автолоад: катсцене нужны узлы сцены (камера, UI, NPC),
## её жизненный цикл — один проход; автолоад потребовал бы правку project.godot
## и ручного поиска всего дерева. Интегратор добавляет один инстанс, все
## зависимости (игрок, HUD, QuestState, DialogueManager) находятся по группам
## и автолоадам.
##
## Публичный API:
##   start(cutscene_id, force = false) -> bool
##   skip() -> bool
##   is_playing() -> bool
##   get_current_id() -> String
##   get_time() -> float
##   get_progress() -> float
##   get_cutscene_camera() -> Camera3D
##   has_seen(cutscene_id) -> bool
##   get_pending_id() -> String
##   set_autostart_enabled(value)
##   reload_data()
## Сигналы:
##   cutscene_started(id), cutscene_finished(id, skipped),
##   step_executed(id, type, t), subtitle_shown(speaker, text), title_shown(text)
##
## Триггеры (autostart_enabled):
##   cut_prologue     — новая игра (нет save.json), после закрытия title_card;
##   cut_box          — флаг twin_box_found, один раз;
##   cut_weapon_alt   — ending_id == 2 + weapon_discharged;
##   cut_weapon       — флаг weapon_discharged, после конца guard_confront.
## Сцена, которая уже виделась (seen_flag в QuestState), не запускается.
## Если в момент флага идёт диалог — сцена ждёт dialogue_ended.

signal cutscene_started(cutscene_id: String)
signal cutscene_finished(cutscene_id: String, skipped: bool)
signal step_executed(cutscene_id: String, step_type: String, time: float)
signal subtitle_shown(speaker: String, text: String)
signal title_shown(text: String)

const CUTSCENE_DATA := preload("res://scripts/game/cutscene_data.gd")
const SAVE_SYSTEM := preload("res://scripts/game/save_system.gd")
const PLAYER_GROUP := "player"
const HUD_GROUP := "hud"
const NPC_GROUP := "npc"
const TITLE_GROUP := "title_card"

@export var autostart_enabled: bool = true
@export var play_prologue_on_new_game: bool = true
@export var debug_logging: bool = true

@onready var cutscene_camera: Camera3D = $CutsceneCamera
@onready var ui_layer: CanvasLayer = $UI
@onready var fade_rect: ColorRect = $UI/Fade
@onready var flash_rect: ColorRect = $UI/Flash
@onready var subtitle_panel: PanelContainer = $UI/SubtitlePanel
@onready var speaker_label: Label = $UI/SubtitlePanel/Margin/VBox/SpeakerLabel
@onready var subtitle_label: Label = $UI/SubtitlePanel/Margin/VBox/SubtitleLabel
@onready var title_label: Label = $UI/TitleLabel

var _quest: Node = null
var _dialogue_manager: Node = null
var _player: Node = null
var _player_camera: Camera3D = null
var _interactor: Node = null
var _title_card: Node = null

var _playing: bool = false
var _cutscene_id: String = ""
var _data: Dictionary = {}
var _steps: Array = []
var _step_index: int = 0
var _time: float = 0.0
var _duration: float = 0.0
var _skippable: bool = true
var _pending_id: String = ""
var _next_dialogue: String = ""
var _waiting_title: bool = false

var _previous_autosave: bool = true
var _ending_active: bool = false
var _hud_state: Array[Dictionary] = []
var _hidden_labels: Array[Dictionary] = []
var _npc_layers: Dictionary = {}
var _warned_missing: Dictionary = {}

var _cam_from: Vector3 = Vector3.ZERO
var _cam_to: Vector3 = Vector3.ZERO
var _cam_look_from: Vector3 = Vector3.ZERO
var _cam_look_to: Vector3 = Vector3.ZERO
var _cam_move_start: float = 0.0
var _cam_move_duration: float = 0.0
var _cam_move_active: bool = false

var _pm_from: Vector3 = Vector3.ZERO
var _pm_to: Vector3 = Vector3.ZERO
var _pm_start: float = 0.0
var _pm_duration: float = 0.0
var _pm_active: bool = false
var _pm_face: bool = true
var _pm_yaw: float = 0.0
var _pm_has_yaw: bool = false

var _npc_moves: Array[Dictionary] = []

var _end_position: Variant = null
var _end_yaw: Variant = null
var _subtitle_hide_at: float = -1.0
var _title_hide_at: float = -1.0

var _fade_tween: Tween = null
var _flash_tween: Tween = null


func _ready() -> void:
	add_to_group("cutscene_player")
	_quest = get_node_or_null("/root/QuestState")
	_dialogue_manager = get_node_or_null("/root/DialogueManager")
	cutscene_camera.current = false
	ui_layer.visible = false
	set_process(false)
	set_process_input(false)
	_connect_autoload_signals()
	call_deferred("_setup_scene_links")


# --- Публичный API -----------------------------------------------------------


func start(cutscene_id: String, force: bool = false) -> bool:
	if _playing:
		return false
	var data := CUTSCENE_DATA.get_cutscene(cutscene_id)
	if data.is_empty():
		push_warning("[cutscene] нет данных катсцены «%s»" % cutscene_id)
		return false
	if not force and has_seen(cutscene_id):
		if debug_logging:
			print("[cutscene] «%s» уже просмотрена — пропуск" % cutscene_id)
		return false
	if not force and cutscene_id == "cut_prologue" and SAVE_SYSTEM.has_save():
		return false
	if _is_dialogue_active():
		_pending_id = cutscene_id
		return false

	_data = data
	_cutscene_id = cutscene_id
	_steps = CUTSCENE_DATA.get_steps(data)
	_duration = CUTSCENE_DATA.get_duration(data)
	_skippable = bool(data.get("skippable", true))
	_step_index = 0
	_time = 0.0
	_pending_id = ""
	_next_dialogue = ""
	_end_position = null
	_end_yaw = null
	_subtitle_hide_at = -1.0
	_title_hide_at = -1.0
	_cam_move_active = false
	_pm_active = false
	_npc_moves.clear()
	_ending_active = _quest != null and _quest.has_method("is_finished") and bool(_quest.call("is_finished"))
	_playing = true

	_find_player()
	_lock_player(true)
	_hide_hud_elements()
	_hide_npc_labels()
	_activate_camera()

	# Флаг «просмотрено» ставим сразу, но автосейв на время сцены выключен:
	# при аварийном выходе состояние не считается завершённым, а позицию
	# сохранит финальный set + save_game.
	if _quest != null:
		_previous_autosave = bool(_quest.get("auto_save_enabled"))
		_quest.set("auto_save_enabled", false)
		_mark_seen()

	ui_layer.visible = true
	subtitle_panel.visible = false
	title_label.visible = false
	var fade_in := float(_data.get("fade_in", 0.0))
	if fade_in > 0.0:
		_apply_fade_alpha(1.0)
		_fade_to(0.0, fade_in)
	else:
		_apply_fade_alpha(0.0)

	set_process(true)
	set_process_input(true)
	cutscene_started.emit(_cutscene_id)
	if debug_logging:
		print("[cutscene] старт «%s» (%.1f с, шагов %d)" % [
			_cutscene_id, _duration, _steps.size()
		])
	_execute_due_steps()
	return true


## Мгновенно завершить катсцену в конечном состоянии.
func skip() -> bool:
	if not _playing:
		return false
	if not _skippable:
		return false
	_finish(true)
	return true


func is_playing() -> bool:
	return _playing


func get_current_id() -> String:
	return _cutscene_id


func get_time() -> float:
	return _time


func get_progress() -> float:
	return clampf(_time / maxf(_duration, 0.001), 0.0, 1.0)


func get_cutscene_camera() -> Camera3D:
	return cutscene_camera


func has_seen(cutscene_id: String) -> bool:
	var data := CUTSCENE_DATA.get_cutscene(cutscene_id)
	if data.is_empty():
		return false
	var flag := CUTSCENE_DATA.get_seen_flag(data)
	if flag.is_empty() or _quest == null:
		return false
	return bool(_quest.call("has_flag", flag))


func get_pending_id() -> String:
	return _pending_id


func set_autostart_enabled(value: bool) -> void:
	autostart_enabled = value


func reload_data() -> void:
	CUTSCENE_DATA.load_all(true)


# --- Ввод и скип -------------------------------------------------------------


func _input(event: InputEvent) -> void:
	if not _playing:
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			if key_event.keycode == KEY_ESCAPE or key_event.keycode == KEY_SPACE:
				if _skippable:
					skip()
					get_viewport().set_input_as_handled()


# --- Жизненный цикл ----------------------------------------------------------


func _process(delta: float) -> void:
	if not _playing:
		return
	_time += delta
	_execute_due_steps()
	_update_camera_move()
	_update_player_move()
	_update_npc_moves()
	if _subtitle_hide_at >= 0.0 and _time >= _subtitle_hide_at:
		subtitle_panel.visible = false
		_subtitle_hide_at = -1.0
	if _title_hide_at >= 0.0 and _time >= _title_hide_at:
		title_label.visible = false
		_title_hide_at = -1.0
	if _time >= _duration:
		_finish(false)


func _execute_due_steps() -> void:
	while _step_index < _steps.size():
		var step_variant: Variant = _steps[_step_index]
		if typeof(step_variant) != TYPE_DICTIONARY:
			_step_index += 1
			continue
		var step: Dictionary = step_variant
		if float(step.get("t", 0.0)) > _time + 0.0001:
			break
		_execute_step(step)
		_step_index += 1


func _execute_step(step: Dictionary) -> void:
	var step_type := str(step.get("type", "")).strip_edges()
	match step_type:
		"camera":
			_apply_camera_step(step, false)
		"player_move":
			_apply_player_move(step)
		"line":
			_show_line(step)
		"title":
			_show_title(step)
		"fade":
			_fade_to(float(step.get("alpha", 0.0)), float(step.get("duration", 0.0)))
		"flash":
			_flash(float(step.get("alpha", 0.8)), float(step.get("duration", 0.18)))
		"flag":
			if _quest != null:
				_quest.call("set_flag", str(step.get("flag", "")), step.get("value", true))
		"objective":
			if _quest != null:
				_quest.call("set_objective", str(step.get("text", "")))
		"item_add":
			if _quest != null:
				_quest.call("add_item", str(step.get("item", "")), str(step.get("name", "")))
		"item_remove":
			if _quest != null:
				_quest.call("remove_item", str(step.get("item", "")))
		"sfx":
			_play_sfx(step)
		"npc":
			_set_npc_visible(str(step.get("npc_id", "")), bool(step.get("visible", true)))
		"npc_move":
			_start_npc_move(step)
		"end":
			_apply_end(step)
		_:
			if debug_logging:
				push_warning("[cutscene] неизвестный шаг «%s»" % step_type)
	step_executed.emit(_cutscene_id, step_type, _time)


func _finish(skipped: bool) -> void:
	if not _playing:
		return
	_playing = false
	set_process(false)
	set_process_input(false)

	# Скип пропускает картинку, но не состояние: дожимаем все оставшиеся
	# сюжетные шаги (флаги/цель/предмет/конец).
	while _step_index < _steps.size():
		var step_variant: Variant = _steps[_step_index]
		_step_index += 1
		if typeof(step_variant) != TYPE_DICTIONARY:
			continue
		var step: Dictionary = step_variant
		var step_type := str(step.get("type", ""))
		if step_type in ["flag", "objective", "item_add", "item_remove", "end"]:
			_execute_step(step)

	if _end_position != null and _player != null and is_instance_valid(_player):
		_player.call("teleport_to", _end_position)
		if _end_yaw != null:
			(_player as Node3D).rotation.y = float(_end_yaw)

	if _quest != null:
		_mark_seen()
		_quest.set("auto_save_enabled", _previous_autosave)
		if _previous_autosave and _player != null and is_instance_valid(_player):
			SAVE_SYSTEM.save_game(_player)

	_restore_camera()
	_restore_hud_elements()
	_restore_npc_labels()
	subtitle_panel.visible = false
	title_label.visible = false
	_apply_fade_alpha(0.0)
	ui_layer.visible = false
	if _fade_tween != null:
		_fade_tween.kill()
		_fade_tween = null
	if _flash_tween != null:
		_flash_tween.kill()
		_flash_tween = null

	var follow_up := not _next_dialogue.is_empty()
	_restore_player_control(not _ending_active and not follow_up)
	if _ending_active:
		# Титр концовки HUD покажет сам: он уже стоит и ждёт, пока мы вернём HUD.
		pass

	var finished_id := _cutscene_id
	var was_skipped := skipped
	cutscene_finished.emit(finished_id, was_skipped)
	if debug_logging:
		print("[cutscene] финиш «%s» (скип=%s, t=%.2f)" % [
			finished_id, str(was_skipped), _time
		])
	_data = {}
	_steps.clear()
	_cutscene_id = ""
	if follow_up:
		call_deferred("_start_follow_up_dialogue", _next_dialogue)


func _start_follow_up_dialogue(dialogue_id: String) -> void:
	if _dialogue_manager == null or dialogue_id.is_empty():
		return
	if _dialogue_manager.has_method("start"):
		var started := bool(_dialogue_manager.call("start", dialogue_id))
		if debug_logging:
			print("[cutscene] следующая сцена-диалог «%s»: %s" % [
				dialogue_id, "ok" if started else "не запустилась"
			])


# --- Камера ------------------------------------------------------------------


func _activate_camera() -> void:
	_find_player_camera()
	if _player_camera != null:
		_player_camera.current = false
	cutscene_camera.current = true


func _restore_camera() -> void:
	cutscene_camera.current = false
	if _player_camera != null and is_instance_valid(_player_camera):
		_player_camera.current = true


func _apply_camera_step(step: Dictionary, initial: bool) -> void:
	var position_value: Variant = step.get("pos", null)
	if typeof(position_value) == TYPE_ARRAY:
		cutscene_camera.global_position = _vec(step, "pos", cutscene_camera.global_position)
	elif initial:
		# Первый шаг без pos: не двигаем камеру, но фиксируем стартовую позу.
		pass
	var look_value: Variant = step.get("look_at", null)
	if typeof(look_value) == TYPE_ARRAY:
		_look_at(cutscene_camera, _vec(step, "look_at", cutscene_camera.global_position + Vector3.FORWARD))
	if step.has("fov"):
		cutscene_camera.fov = float(step.get("fov", 58.0))
	if step.has("to"):
		_cam_from = cutscene_camera.global_position
		_cam_to = _vec(step, "to", _cam_from)
		_cam_look_from = _current_look_target()
		_cam_look_to = _vec(step, "look_at_to", _cam_look_from)
		_cam_move_start = _time
		_cam_move_duration = maxf(float(step.get("duration", 1.0)), 0.01)
		_cam_move_active = true
	else:
		_cam_move_active = false


func _update_camera_move() -> void:
	if not _cam_move_active:
		return
	var progress := clampf((_time - _cam_move_start) / _cam_move_duration, 0.0, 1.0)
	var eased := _ease(progress, "in_out")
	cutscene_camera.global_position = _cam_from.lerp(_cam_to, eased)
	_look_at(cutscene_camera, _cam_look_from.lerp(_cam_look_to, eased))
	if progress >= 1.0:
		_cam_move_active = false


func _current_look_target() -> Vector3:
	var basis := cutscene_camera.global_transform.basis
	return cutscene_camera.global_position - basis.z * 10.0


func _look_at(camera: Camera3D, target: Vector3) -> void:
	if camera.global_position.distance_squared_to(target) < 0.000001:
		return
	camera.look_at(target, Vector3.UP)


func _ease(value: float, mode: String) -> float:
	match mode:
		"in":
			return value * value
		"out":
			return 1.0 - (1.0 - value) * (1.0 - value)
		"in_out":
			return value * value * (3.0 - 2.0 * value)
		_:
			return value


# --- Игрок -------------------------------------------------------------------


func _apply_player_move(step: Dictionary) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	_pm_from = _vec(step, "from", (_player as Node3D).global_position)
	_pm_to = _vec(step, "to", _pm_from)
	_pm_start = _time
	_pm_duration = maxf(float(step.get("duration", 1.0)), 0.01)
	_pm_face = bool(step.get("face_movement", true))
	_pm_has_yaw = step.has("yaw")
	_pm_yaw = float(step.get("yaw", 0.0))
	_pm_active = true
	(_player as Node3D).global_position = _pm_from


func _update_player_move() -> void:
	if not _pm_active or _player == null or not is_instance_valid(_player):
		return
	var progress := clampf((_time - _pm_start) / _pm_duration, 0.0, 1.0)
	var eased := _ease(progress, "in_out")
	var next_position := _pm_from.lerp(_pm_to, eased)
	(_player as Node3D).global_position = next_position
	if _player.has_method("teleport_to"):
		_player.set("velocity", Vector3.ZERO)
	if _pm_has_yaw:
		(_player as Node3D).rotation.y = _pm_yaw
	elif _pm_face:
		var dir := _pm_to - _pm_from
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			(_player as Node3D).rotation.y = atan2(-dir.x, -dir.z)
	if progress >= 1.0:
		_pm_active = false


# --- Субтитры, титры, затемнение ---------------------------------------------


func _show_line(step: Dictionary) -> void:
	var line := CUTSCENE_DATA.resolve_line(step)
	var speaker := str(line.get("speaker", "")).strip_edges()
	var text := str(line.get("text", "")).strip_edges()
	if text.is_empty():
		return
	speaker_label.text = speaker
	speaker_label.visible = not speaker.is_empty()
	subtitle_label.text = text
	subtitle_panel.visible = true
	var hold := float(step.get("duration", 0.0))
	if hold <= 0.0:
		hold = clampf(float(text.length()) * 0.06, 1.2, 4.5)
	_subtitle_hide_at = _time + hold
	subtitle_shown.emit(speaker, text)
	if debug_logging:
		print("[cutscene] реплика %s: «%s»" % [speaker, text])
	var dialogue_id := str(line.get("dialogue_id", ""))
	var node_id := str(line.get("node_id", ""))
	if not dialogue_id.is_empty() and not node_id.is_empty():
		var audio := get_node_or_null("/root/AudioManager")
		if audio != null and audio.has_method("play_voice"):
			audio.call("play_voice", dialogue_id, node_id)


func _show_title(step: Dictionary) -> void:
	var text := str(step.get("text", "")).strip_edges()
	if text.is_empty():
		return
	title_label.text = text
	title_label.visible = true
	var hold := maxf(float(step.get("duration", 1.5)), 0.1)
	_title_hide_at = _time + hold
	title_shown.emit(text)


func _apply_fade_alpha(alpha: float) -> void:
	var color := fade_rect.color
	color.a = clampf(alpha, 0.0, 1.0)
	fade_rect.color = color
	fade_rect.visible = color.a > 0.001


func _fade_to(alpha: float, duration: float) -> void:
	if _fade_tween != null:
		_fade_tween.kill()
	_fade_tween = null
	var target := clampf(alpha, 0.0, 1.0)
	var color := fade_rect.color
	color.a = clampf(color.a, 0.0, 1.0)
	fade_rect.color = color
	fade_rect.visible = true
	if duration <= 0.0:
		_apply_fade_alpha(target)
		return
	_fade_tween = create_tween()
	_fade_tween.set_trans(Tween.TRANS_SINE)
	_fade_tween.tween_property(fade_rect, "color:a", target, duration)
	_fade_tween.tween_callback(func() -> void:
		fade_rect.visible = target > 0.001
	)


func _flash(alpha: float, duration: float) -> void:
	if _flash_tween != null:
		_flash_tween.kill()
	var color := flash_rect.color
	color.a = clampf(alpha, 0.0, 1.0)
	flash_rect.color = color
	flash_rect.visible = true
	_flash_tween = create_tween()
	_flash_tween.tween_property(flash_rect, "color:a", 0.0, maxf(duration, 0.02))
	_flash_tween.tween_callback(func() -> void:
		flash_rect.visible = false
	)


# --- NPC ---------------------------------------------------------------------


func _start_npc_move(step: Dictionary) -> void:
	var npc := _find_npc(str(step.get("npc_id", "")))
	if npc == null:
		return
	var from := _vec(step, "from", (npc as Node3D).global_position)
	var to := _vec(step, "to", from)
	(npc as Node3D).global_position = from
	_npc_moves.append({
		"node": npc,
		"from": from,
		"to": to,
		"start": _time,
		"duration": maxf(float(step.get("duration", 1.0)), 0.01),
	})


func _update_npc_moves() -> void:
	for index in range(_npc_moves.size() - 1, -1, -1):
		var move: Dictionary = _npc_moves[index]
		var npc: Variant = move.get("node")
		if npc == null or not is_instance_valid(npc):
			_npc_moves.remove_at(index)
			continue
		var progress := clampf((_time - float(move.get("start", 0.0))) / float(move.get("duration", 1.0)), 0.0, 1.0)
		var from: Vector3 = move.get("from", Vector3.ZERO)
		var to: Vector3 = move.get("to", Vector3.ZERO)
		(npc as Node3D).global_position = from.lerp(to, _ease(progress, "in_out"))
		if progress >= 1.0:
			_npc_moves.remove_at(index)


func _set_npc_visible(npc_id: String, value: bool) -> void:
	var npc := _find_npc(npc_id)
	if npc == null:
		return
	var key := npc.get_instance_id()
	if not _npc_layers.has(key):
		_npc_layers[key] = (npc as Node3D).collision_layer
	if value:
		(npc as Node3D).visible = true
		(npc as Node3D).collision_layer = int(_npc_layers.get(key, 1))
	else:
		(npc as Node3D).visible = false
		(npc as Node3D).collision_layer = 0


func _find_npc(npc_id: String) -> Node3D:
	if npc_id.is_empty() or not is_inside_tree():
		return null
	for node in get_tree().get_nodes_in_group(NPC_GROUP):
		var npc := node as Node3D
		if npc == null or not is_instance_valid(npc):
			continue
		var id := str(npc.get_meta("npc_id", ""))
		if id.is_empty() and npc.get("npc_id") != null:
			id = str(npc.get("npc_id"))
		if id == npc_id:
			return npc
	if not _warned_missing.has(npc_id):
		_warned_missing[npc_id] = true
		if debug_logging:
			print("[cutscene] NPC «%s» не найден — шаг пропущен" % npc_id)
	return null


# --- Связи и восстановление сцены -------------------------------------------


func _connect_autoload_signals() -> void:
	if _quest != null:
		if _quest.has_signal("flag_changed"):
			_quest.connect("flag_changed", _on_quest_changed)
		if _quest.has_signal("ending_reached"):
			_quest.connect("ending_reached", _on_ending_reached)
	if _dialogue_manager != null and _dialogue_manager.has_signal("dialogue_ended"):
		_dialogue_manager.connect("dialogue_ended", _on_dialogue_ended)


func _setup_scene_links() -> void:
	_find_player()
	_find_title_card()


func _find_player() -> void:
	if _player != null and is_instance_valid(_player):
		return
	if not is_inside_tree():
		return
	_player = get_tree().get_first_node_in_group(PLAYER_GROUP)
	if _player != null:
		if _player.has_method("get_camera"):
			_player_camera = _player.call("get_camera") as Camera3D
		if _player.has_method("get_interactor"):
			_interactor = _player.call("get_interactor")


func _find_player_camera() -> void:
	if _player == null or not is_instance_valid(_player):
		_find_player()
	if _player_camera == null and _player != null and _player.has_method("get_camera"):
		_player_camera = _player.call("get_camera") as Camera3D


func _find_title_card() -> void:
	for node in get_tree().get_nodes_in_group(TITLE_GROUP):
		if node.has_signal("title_dismissed"):
			_title_card = node
			if not _title_card.is_connected("title_dismissed", _on_title_dismissed):
				_title_card.connect("title_dismissed", _on_title_dismissed)
			if _title_card.has_method("is_open") and bool(_title_card.call("is_open")):
				_waiting_title = true
			break
	if not _waiting_title and autostart_enabled:
		call_deferred("_maybe_auto_start")


func _on_title_dismissed() -> void:
	_waiting_title = false
	if autostart_enabled:
		call_deferred("_maybe_auto_start")


func _on_dialogue_ended(_dialogue_id: String, _ending_id: int) -> void:
	if autostart_enabled:
		call_deferred("_maybe_auto_start")


func _on_quest_changed(_flag: String, _value: Variant) -> void:
	if autostart_enabled:
		call_deferred("_maybe_auto_start")


func _on_ending_reached(_ending_id: int, _title: String) -> void:
	if autostart_enabled:
		call_deferred("_maybe_auto_start")


func _maybe_auto_start() -> void:
	if not autostart_enabled or _playing or _waiting_title:
		return
	if not is_inside_tree():
		return
	if _is_dialogue_active():
		if _pending_id.is_empty():
			_pending_id = _pick_trigger()
		return
	var next_id := _pending_id
	if next_id.is_empty():
		next_id = _pick_trigger()
	if next_id.is_empty():
		return
	_pending_id = ""
	start(next_id)


func _pick_trigger() -> String:
	if _quest == null:
		return ""
	if play_prologue_on_new_game and not has_seen("cut_prologue") and not SAVE_SYSTEM.has_save():
		return "cut_prologue"
	if _quest.call("has_flag", "twin_box_found") and not has_seen("cut_box"):
		return "cut_box"
	if (
		int(_quest.call("get_ending_id")) == 2
		and _quest.call("has_flag", "weapon_discharged")
		and not has_seen("cut_weapon_alt")
	):
		return "cut_weapon_alt"
	if _quest.call("has_flag", "weapon_discharged") and not has_seen("cut_weapon"):
		return "cut_weapon"
	return ""


func _is_dialogue_active() -> bool:
	if _dialogue_manager == null:
		_dialogue_manager = get_node_or_null("/root/DialogueManager")
	return (
		_dialogue_manager != null
		and _dialogue_manager.has_method("is_active")
		and bool(_dialogue_manager.call("is_active"))
	)


func _mark_seen() -> void:
	if _quest == null or _data.is_empty():
		return
	var flag := CUTSCENE_DATA.get_seen_flag(_data)
	if flag.is_empty():
		return
	_quest.call("set_flag", flag, true)


func _lock_player(locked: bool) -> void:
	_find_player()
	if _player == null:
		return
	if _player.has_method("set_controls_enabled"):
		_player.call("set_controls_enabled", not locked)
	if _player.has_method("set_mouse_captured"):
		if DisplayServer.get_name() != "headless":
			_player.call("set_mouse_captured", not locked)
	if _interactor == null and _player.has_method("get_interactor"):
		_interactor = _player.call("get_interactor")
	if _interactor != null and _interactor.has_method("set_interaction_enabled"):
		_interactor.call("set_interaction_enabled", not locked)


func _restore_player_control(enabled: bool) -> void:
	_find_player()
	if _player == null:
		return
	if _player.has_method("set_controls_enabled"):
		_player.call("set_controls_enabled", enabled)
	if _player.has_method("set_mouse_captured"):
		if DisplayServer.get_name() != "headless":
			_player.call("set_mouse_captured", enabled)
	if _interactor == null and _player.has_method("get_interactor"):
		_interactor = _player.call("get_interactor")
	if _interactor != null and _interactor.has_method("set_interaction_enabled"):
		_interactor.call("set_interaction_enabled", enabled)


func _hide_hud_elements() -> void:
	_hud_state.clear()
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group(HUD_GROUP):
		if not node is CanvasItem:
			continue
		var item := node as CanvasItem
		_hud_state.append({"node": item, "visible": item.visible})
		item.visible = false
		if node.has_method("hide_hint"):
			node.call("hide_hint")


func _restore_hud_elements() -> void:
	for entry in _hud_state:
		var node: Variant = entry.get("node")
		if node != null and is_instance_valid(node):
			(node as CanvasItem).visible = bool(entry.get("visible", true))
	_hud_state.clear()


func _hide_npc_labels() -> void:
	_hidden_labels.clear()
	if not is_inside_tree():
		return
	for npc in get_tree().get_nodes_in_group(NPC_GROUP):
		for label_node in npc.find_children("*", "Label3D", true, false):
			var label := label_node as Label3D
			if label == null or not label.visible:
				continue
			_hidden_labels.append({"node": label})
			label.visible = false


func _restore_npc_labels() -> void:
	for entry in _hidden_labels:
		var node: Variant = entry.get("node")
		if node != null and is_instance_valid(node):
			(node as Label3D).visible = true
	_hidden_labels.clear()


# --- Мелкие помощники --------------------------------------------------------


func _vec(source: Dictionary, key: String, fallback: Vector3) -> Vector3:
	var value: Variant = source.get(key, null)
	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		var array: Array = value
		return Vector3(float(array[0]), float(array[1]), float(array[2]))
	return fallback


func _play_sfx(step: Dictionary) -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio == null or not audio.has_method("play_sfx"):
		return
	var sfx_name := str(step.get("name", "")).strip_edges()
	if sfx_name.is_empty():
		return
	var position_value: Variant = step.get("position", null)
	if typeof(position_value) == TYPE_ARRAY:
		audio.call("play_sfx", sfx_name, _vec(step, "position", Vector3.ZERO))
	else:
		audio.call("play_sfx", sfx_name)


func _apply_end(step: Dictionary) -> void:
	var position_value: Variant = step.get("player_position", null)
	if typeof(position_value) == TYPE_ARRAY:
		_end_position = _vec(step, "player_position", Vector3.ZERO)
	if step.has("player_yaw"):
		_end_yaw = float(step.get("player_yaw", 0.0))
	if _quest != null:
		var set_flag_value := str(step.get("set_flag", "")).strip_edges()
		if not set_flag_value.is_empty():
			_quest.call("set_flag", set_flag_value, true)
		var flags_value: Variant = step.get("flags", null)
		if typeof(flags_value) == TYPE_DICTIONARY:
			for flag_key in (flags_value as Dictionary).keys():
				_quest.call("set_flag", str(flag_key), (flags_value as Dictionary)[flag_key])
		var remove_value := str(step.get("remove_item", "")).strip_edges()
		if not remove_value.is_empty():
			_quest.call("remove_item", remove_value)
		var objective_value := str(step.get("objective", "")).strip_edges()
		if not objective_value.is_empty():
			_quest.call("set_objective", objective_value)
		var next_value := str(step.get("next_dialogue", "")).strip_edges()
		if not next_value.is_empty():
			_next_dialogue = next_value
	var skip_flag_value := str(step.get("set_flag_on_finish", "")).strip_edges()
	if not skip_flag_value.is_empty() and _quest != null:
		_quest.call("set_flag", skip_flag_value, true)
