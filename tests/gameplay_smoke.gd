extends Node
## T16 gameplay smoke — проход квеста без UI:
##   коробка с прилавка -> в руках -> стойка прораба -> флаги/стадии ->
##   save/load round-trip (позиция, стадия, флаги, инвентарь, состояние предмета) ->
##   старый save.json (миграция) -> requires в диалогах -> маркер цели.
##
## Запуск:
##   tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . tests/gameplay_smoke.tscn
## Успех: код 0 и строка "T16 GAMEPLAY SMOKE OK" в tools\t16_smoke.log.

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const PACKAGE_SCENE := "res://scenes/objects/package.tscn"
const DROP_ZONE_SCENE := "res://scenes/objects/package_drop_zone.tscn"
const MARKER_SCRIPT := "res://scripts/game/objective_marker.gd"
const LOG_PATH := "res://tools/t16_smoke.log"
const MARKER_OK := "T16 GAMEPLAY SMOKE OK"

var _failures: Array[String] = []
var _checks: int = 0
var _log_lines: PackedStringArray = PackedStringArray()

var _quest: Node = null
var _dm: Node = null
var _player: Player = null
var _package: CarriedItem = null
var _zone: ItemDropZone = null


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_log("=== T16 GAMEPLAY SMOKE START ===")
	await get_tree().process_frame
	_quest = get_node_or_null("/root/QuestState")
	_dm = get_node_or_null("/root/DialogueManager")
	_expect(_quest != null, "нет автолоада QuestState")
	_expect(_dm != null, "нет автолоада DialogueManager")
	if _quest == null or _dm == null:
		_finish()
		return

	_quest.auto_save_enabled = false
	_quest.reset()

	await _build_sandbox()
	_test_pickup()
	await _wait_physics_frames(3)
	_check_carried_pose()
	await _test_drop()
	await _test_item_restore_from_state()
	_test_stage_chain_before_save()
	await _test_save_load_round_trip()
	_test_stage_chain_after_save()
	_test_old_save_migration()
	_test_requires_filter()
	_test_finale_requires()
	await _test_quest_director()
	await _test_objective_marker()
	_finish()


# --- Подготовка песочницы ---------------------------------------------------


func _build_sandbox() -> void:
	# Пол, чтобы игрок не падал в пустоту во время физических кадров.
	var floor_body := StaticBody3D.new()
	floor_body.name = "SmokeFloor"
	floor_body.collision_layer = 1
	floor_body.collision_mask = 1
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(40.0, 0.5, 40.0)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0.0, -0.25, 0.0)
	floor_body.add_child(floor_shape)
	add_child(floor_body)

	_player = (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
	_player.position = Vector3(0.0, 0.1, 0.0)
	add_child(_player)
	await _wait_physics_frames(5)

	# Коробка стоит на прилавке магазина (метка 0, 1.2, 2).
	_package = (load(PACKAGE_SCENE) as PackedScene).instantiate() as CarriedItem
	_package.name = "SmokePackage"
	_package.position = Vector3(0.0, 1.2, 2.0)
	add_child(_package)
	await get_tree().process_frame
	await get_tree().process_frame

	# Стойка прораба: зона, в которую кладут коробку.
	_zone = (load(DROP_ZONE_SCENE) as PackedScene).instantiate() as ItemDropZone
	_zone.name = "SmokeDropZone"
	_zone.position = Vector3(2.0, 0.0, 2.0)
	add_child(_zone)
	await get_tree().process_frame

	_expect(_package.item_state == CarriedItem.ItemState.PLACED,
		"коробка должна начинать на прилавке (state=%s)" % _package.get_state_name())
	_expect(_package.get_meta("interactable", false) == true,
		"у коробки нет метаданных interactable")
	_expect(_package.is_in_group("carried_items"), "коробка не в группе carried_items")
	_log("[sandbox] игрок=%s коробка=%s зона=%s" % [
		_player.global_position, _package.global_position, _zone.global_position
	])


# --- Коробка: взять / нести / положить --------------------------------------


var _picked_signals: int = 0
var _dropped_signals: int = 0


func _test_pickup() -> void:
	_package.picked_up.connect(func(_item: CarriedItem) -> void: _picked_signals += 1)
	_package.dropped.connect(func(_item: CarriedItem, _target: Node) -> void: _dropped_signals += 1)
	var ok := _package.pick_up(_player)
	_expect(ok, "pick_up вернул false")
	_expect(_picked_signals == 1, "сигнал picked_up не пришёл (получено %d)" % _picked_signals)
	_expect(_package.is_carried(), "коробка не перешла в CARRIED")
	_expect(_quest.has_item("package"), "в инвентаре QuestState нет package")
	_expect(_quest.has_flag("item_package"), "флаг item_package не выставлен")
	_expect(_package.collision_layer == 0, "у несомой коробки не отключена коллизия")
	_expect(_quest.get_item_state("package").get("state", "") == "carried",
		"item_state не стал carried")
	_expect(_picked_signals == 1, "picked_up должен сработать ровно один раз")


func _check_carried_pose() -> void:
	var expected: Vector3 = (
		_player.global_position + _player.global_transform.basis * _package.chest_offset
	)
	var distance := _package.global_position.distance_to(expected)
	_expect(distance < 0.06, "коробка не у груди игрока: offset=%.3f" % distance)
	_expect(absf(_package.global_position.y - _player.global_position.y) < 1.6,
		"коробка слишком высоко/низко (y=%.2f)" % _package.global_position.y)
	_log("[carry] коробка в руках: pos=%s, offset=%.3f" % [_package.global_position, distance])


func _test_drop() -> void:
	_expect(_zone.can_accept(_package), "зона не принимает коробку")
	_zone.interact(_player)
	await get_tree().process_frame
	_expect(_dropped_signals == 1, "сигнал dropped не пришёл (получено %d)" % _dropped_signals)
	_expect(not _package.is_carried(), "коробка всё ещё в руках после drop_at")
	_expect(not _quest.has_item("package"), "коробка осталась в инвентаре после сдачи")
	_expect(not _quest.has_flag("item_package"), "флаг item_package остался true")
	_expect(_quest.has_flag("package_placed"), "флаг package_placed не выставлен")
	var expected: Vector3 = _zone.global_position + _zone.drop_offset
	var distance := _package.global_position.distance_to(expected)
	_expect(distance < 0.03, "коробка не на стойке прораба: offset=%.3f" % distance)
	_expect(_quest.get_item_state("package").get("state", "") == "dropped",
		"item_state не стал dropped")
	_log("[drop] коробка на стойке: pos=%s, offset=%.3f" % [_package.global_position, distance])


# --- Стадии до сохранения ---------------------------------------------------


func _test_stage_chain_before_save() -> void:
	_expect_stage("deliver_package", "стартовая стадия")
	_quest.set_flag("package_delivered")
	_expect_stage("check_answerphone", "после package_delivered")
	_quest.set_flag("night_started")
	_expect_stage("reach_dispatcher", "после night_started")
	_quest.set_flag("shift_log_seen")
	_expect_stage("find_site_code", "после shift_log_seen")
	_quest.set_flag("site_code", "4-0-7")
	_expect_stage("inspect_twin_box", "после site_code")
	var stages: Array = _quest.get_stages()
	_expect(stages.size() == 10, "стадий должно быть 10, а %d" % stages.size())
	_expect(bool(stages[0].get("completed", false)), "первая стадия не отмечена выполненной")
	_expect(bool(stages[4].get("active", false)), "текущая стадия (inspect_twin_box) не active")
	_log("[stages] %s" % _stages_line())


# --- Сохранение / загрузка --------------------------------------------------


func _test_save_load_round_trip() -> void:
	_quest.add_item("flashlight", "Фонарь")
	_expect(_quest.has_item("flashlight"), "фонарь не добавился в инвентарь")
	var saved_position := Vector3(4.0, 0.1, 4.0)
	_player.teleport_to(saved_position)
	await _wait_physics_frames(2)
	# Физика успевает прижать игрока к полу — сохраняем фактическую позицию.
	saved_position = _player.global_position
	var saved_ok := SaveSystem.save_game(_player)
	_expect(saved_ok, "SaveSystem.save_game вернул false")

	_quest.reset()
	_player.teleport_to(Vector3(-5.0, 0.1, -5.0))
	_expect(_quest.get_current_stage_id() == "deliver_package", "reset не вернул стартовую стадию")
	var loaded_ok := SaveSystem.load_game(_player)
	_expect(loaded_ok, "SaveSystem.load_game вернул false")
	await get_tree().process_frame

	_expect(_player.global_position.distance_to(saved_position) < 0.01,
		"позиция игрока не восстановилась: %s" % _player.global_position)
	_expect(_quest.get_current_stage_id() == "inspect_twin_box",
		"стадия не восстановилась: %s" % _quest.get_current_stage_id())
	_expect(_quest.has_flag("package_delivered"), "флаг package_delivered потерян")
	_expect(_quest.has_flag("night_started"), "флаг night_started потерян")
	_expect(_quest.has_flag("shift_log_seen"), "флаг shift_log_seen потерян")
	_expect(str(_quest.get_flag("site_code", "")) == "4-0-7", "site_code потерян")
	_expect(_quest.has_item("flashlight"), "фонарь не восстановился из инвентаря")
	_expect(_quest.has_flag("item_flashlight"), "флаг item_flashlight не восстановился")
	_expect(not _quest.has_item("package"), "коробка ошибочно вернулась в инвентарь")
	_log("[save] round-trip: pos=%s stage=%s items=%s" % [
		_player.global_position, _quest.get_current_stage_id(), _quest.get_items()
	])


# --- Восстановление коробки из item_states ----------------------------------


func _test_item_restore_from_state() -> void:
	var state: Dictionary = _quest.get_item_state("package")
	var saved_position_data: Variant = state.get("position", [])
	_expect(typeof(saved_position_data) == TYPE_ARRAY, "в item_state нет позиции коробки")
	var restored := (load(PACKAGE_SCENE) as PackedScene).instantiate() as CarriedItem
	restored.name = "RestoredPackage"
	restored.position = Vector3(20.0, 1.0, 20.0)
	add_child(restored)
	await get_tree().process_frame
	await get_tree().process_frame
	var restored_state := restored.get_state_name()
	_expect(restored_state == "dropped",
		"коробка не восстановилась как dropped: %s" % restored_state)
	if typeof(saved_position_data) == TYPE_ARRAY and (saved_position_data as Array).size() >= 3:
		var items: Array = saved_position_data
		var expected := Vector3(float(items[0]), float(items[1]), float(items[2]))
		_expect(restored.global_position.distance_to(expected) < 0.05,
			"позиция коробки не восстановилась: %s vs %s" % [restored.global_position, expected])
	_log("[item] восстановление коробки из item_states: %s" % restored_state)
	restored.queue_free()
	await get_tree().process_frame


# --- Стадии после загрузки, финал ------------------------------------------


func _test_stage_chain_after_save() -> void:
	_quest.set_flag("twin_box_found")
	_expect_stage("return_to_mila", "после twin_box_found")
	_quest.set_flag("mila_confessed")
	_expect_stage("find_foreman", "после mila_confessed")
	_quest.set_flag("foreman_cornered")
	_expect_stage("talk_to_kostya", "после foreman_cornered")
	_quest.set_flag("kostya_witness")
	_expect_stage("final_choice", "после kostya_witness")
	_quest.set_ending(3, "Смена")
	_expect_stage("finished", "после set_ending(3)")
	_expect(_quest.get_ending_id() == 3, "ending_id != 3")
	_expect(_quest.get_ending_title() == "Смена", "ending_title != «Смена»")
	_expect(_quest.is_finished(), "квест не завершён после set_ending")
	var stages: Array = _quest.get_stages()
	for index in stages.size() - 1:
		_expect(bool(stages[index].get("completed", false)),
			"стадия %d не completed после финала" % index)
	_expect(bool(stages[stages.size() - 1].get("active", false)), "finished не active")
	_log("[ending] %d «%s», стадии: %s" % [
		_quest.get_ending_id(), _quest.get_ending_title(), _stages_line()
	])


# --- Совместимость со старым save.json --------------------------------------


func _test_old_save_migration() -> void:
	_quest.reset()
	# Формат фазы 1: objective + flags + ending_id/title/completed, без stage/inventory.
	var old_save := {
		"objective": "Проверь автоответчик у входа",
		"flags": {"package_delivered": true, "item_flashlight": true, "mila_warned": true},
		"ending_id": 0,
		"ending_title": "",
		"completed": false,
	}
	_quest.from_dict(old_save)
	_expect(_quest.get_current_stage_id() == "check_answerphone",
		"старый сейв: стадия выведена неверно (%s)" % _quest.get_current_stage_id())
	_expect(_quest.get_objective() == "Проверь автоответчик у входа",
		"старый сейв: цель потеряна (%s)" % _quest.get_objective())
	_expect(_quest.has_item("flashlight"), "старый сейв: item_flashlight не стал инвентарём")
	_expect(_quest.has_flag("mila_warned"), "старый сейв: флаг mila_warned потерян")

	# Старый сейв с концовкой: completed + ending_id должны дать finished.
	var old_ending := {
		"objective": "История завершена",
		"flags": {"package_delivered": true, "ending_delivered": true},
		"ending_id": 2,
		"ending_title": "Голос",
		"completed": true,
	}
	_quest.from_dict(old_ending)
	_expect(_quest.get_current_stage_id() == "finished",
		"старый сейв с концовкой: стадия не finished (%s)" % _quest.get_current_stage_id())
	_expect(_quest.get_ending_id() == 2, "старый сейв: ending_id потерян")
	_expect(_quest.get_ending_title() == "Голос", "старый сейв: ending_title потерян")
	_log("[migrate] старый сейв -> stage=%s items=%s ending=%d" % [
		_quest.get_current_stage_id(), _quest.get_items(), _quest.get_ending_id()
	])


# --- requires в выборе диалога (библия §7.2) --------------------------------


func _test_requires_filter() -> void:
	_quest.reset()
	var fake := {
		"title": "requires smoke",
		"speaker": "Тест",
		"start": "n1",
		"nodes": {
			"n1": {
				"text": "Выбор",
				"choices": [
					{"text": "Всегда", "next": "n2"},
					{
						"text": "Только со флагами",
						"next": "n2",
						"requires": ["shift_log_seen", "twin_box_found"],
					},
				],
			},
			"n2": {"text": "Конец"},
		},
	}
	_dm.get("_dialogues")["__t16_requires"] = fake
	var schema_errors: PackedStringArray = DialogueData._validate_dialogue("__t16_requires", fake)
	_expect(schema_errors.is_empty(),
		"валидатор отверг requires: %s" % ", ".join(schema_errors))

	_expect(_dm.start("__t16_requires"), "фейковый диалог не стартовал")
	_expect(_dm.get_choices().size() == 1,
		"без флагов должно быть 1 видимое choice, а %d" % _dm.get_choices().size())
	_dm.close()

	_quest.set_flag("shift_log_seen")
	_quest.set_flag("twin_box_found")
	_expect(_dm.start("__t16_requires"), "фейковый диалог не стартовал повторно")
	_expect(_dm.get_choices().size() == 2,
		"с флагами должно быть 2 choice, а %d" % _dm.get_choices().size())
	_dm.close()
	_dm.get("_dialogues").erase("__t16_requires")
	_log("[requires] choice 1 -> 2 по флагам, валидатор терпим")


# --- Реальный финал: третий вариант только с тремя флагами ------------------


func _test_finale_requires() -> void:
	_log("[finale] старт проверки requires")
	_quest.reset()
	_expect(_dm.start("finale"), "реальный диалог finale не стартовал")
	_advance_to_choices()
	var without_flags: int = int(_dm.get_choices().size())
	_expect(without_flags == 2,
		"без флагов в финале должно быть 2 варианта, а %d" % without_flags)
	_dm.close()
	_log("[finale] после первого закрытия")

	_quest.set_flag("shift_log_seen")
	_quest.set_flag("twin_box_found")
	_quest.set_flag("foreman_cornered")
	_expect(_dm.start("finale"), "finale не стартовал повторно")
	_advance_to_choices()
	var with_flags: int = int(_dm.get_choices().size())
	_expect(with_flags == 3,
		"с тремя флагами в финале должно быть 3 варианта, а %d" % with_flags)
	# Третий вариант действительно «Закрыть смену».
	if with_flags == 3:
		var choices: Array = _dm.get_choices()
		var third: Dictionary = choices[2] if typeof(choices[2]) == TYPE_DICTIONARY else {}
		_expect(str(third.get("text", "")).contains("Закрыть"),
			"третий вариант финала — не «Закрыть смену»")
	_dm.close()
	_log("[finale] вариантов без флагов %d, с флагами %d" % [without_flags, with_flags])


func _advance_to_choices() -> void:
	var guard := 0
	while _dm.is_active() and not _dm.has_choices() and _dm.has_next_line() and guard < 64:
		print("[finale] advance from '%s'" % _dm.get_current_node_id())
		_dm.advance()
		guard += 1
	print("[finale] choices=%d node='%s'" % [
		_dm.get_choices().size(), _dm.get_current_node_id()
	])


# --- QuestDirector: переключение реплик по акту -----------------------------


func _test_quest_director() -> void:
	_log("[director] старт проверки")
	_quest.reset()
	var director := (load("res://scripts/game/quest_director.gd") as GDScript).new() as QuestDirector
	director.name = "SmokeDirector"
	add_child(director)
	await get_tree().process_frame
	_quest.set_flag("night_started")
	_expect(str(director.resolve_dialogue("voice").get("dialogue", "")) == "voice_log",
		"после night_started автоответчик не переключился на voice_log")
	_expect(bool(director.resolve_dialogue("mila").get("hidden", false)),
		"после night_started Мила должна быть скрыта")
	_quest.set_flag("twin_box_found")
	_expect(str(director.resolve_dialogue("mila").get("dialogue", "")) == "mila_late",
		"после twin_box_found Мила не переключилась на mila_late")
	_quest.set_flag("mila_confessed")
	_expect(str(director.resolve_dialogue("foreman").get("dialogue", "")) == "foreman_late",
		"после mila_confessed Прораб не переключился на foreman_late")
	_quest.set_flag("foreman_cornered")
	_expect(str(director.resolve_dialogue("kostya").get("dialogue", "")) == "kostya_late",
		"после foreman_cornered Костя не переключился на kostya_late")
	_quest.set_flag("kostya_witness")
	_expect(str(director.resolve_dialogue("voice").get("dialogue", "")) == "finale",
		"после kostya_witness автоответчик не переключился на finale")

	# Проверка на живом узле NPC: переключение dialogue_id и скрытие по флагу.
	var npc_scene: PackedScene = load("res://scenes/actors/npc.tscn") as PackedScene
	if npc_scene != null:
		var mila_npc: Node = npc_scene.instantiate()
		mila_npc.name = "SmokeMilaNpc"
		mila_npc.set("npc_id", "mila")
		mila_npc.set("display_name", "Мила")
		mila_npc.set("dialogue_id", "mila")
		mila_npc.set("skin", "mila")
		add_child(mila_npc)
		await get_tree().process_frame
		_quest.reset()
		_quest.set_flag("night_started")
		await get_tree().process_frame
		_expect(not mila_npc.visible, "QuestDirector не скрыл Милу после night_started")
		_expect(mila_npc.collision_layer == 0, "у скрытой Милы осталась коллизия")
		_quest.set_flag("twin_box_found")
		await get_tree().process_frame
		_expect(mila_npc.visible, "QuestDirector не вернул Милу после twin_box_found")
		_expect(str(mila_npc.call("get_dialogue_id")) == "mila_late",
			"у живого NPC не сменился dialogue_id (получили '%s')" % str(mila_npc.call("get_dialogue_id")))
		mila_npc.queue_free()
		await get_tree().process_frame
	else:
		_expect(false, "не загрузилась сцена scenes/actors/npc.tscn")
	director.queue_free()
	await get_tree().process_frame
	_log("[director] dialogue_id NPC переключается по флагам акта")


# --- Маркер цели ------------------------------------------------------------


func _test_objective_marker() -> void:
	_quest.reset()
	_quest.set_stage("find_foreman")
	var marker := (load(MARKER_SCRIPT) as GDScript).new() as ObjectiveMarker
	marker.name = "SmokeMarker"
	marker.stage_id = "find_foreman"
	add_child(marker)
	await get_tree().process_frame
	_expect(marker.is_active(), "маркер текущей стадии не активен")
	_expect(marker.visible, "маркер текущей стадии невидим")
	var light := marker.get_node_or_null("Glow") as OmniLight3D
	_expect(light != null, "у маркера нет мягкого OmniLight")
	var dot := marker.get_node_or_null("Dot") as MeshInstance3D
	_expect(dot != null, "у маркера нет точки")
	_quest.set_stage("talk_to_kostya")
	await get_tree().process_frame
	_expect(not marker.is_active(), "маркер чужой стадии остался активен")
	_expect(not marker.visible, "маркер чужой стадии остался видим")
	marker.queue_free()
	await get_tree().process_frame
	_log("[marker] подсветка переключается по stage_changed")


# --- Утилиты ----------------------------------------------------------------


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures.append(message)
	_log("[FAIL] %s" % message)


func _expect_stage(stage_id: String, context: String) -> void:
	var actual: String = str(_quest.get_current_stage_id())
	_expect(actual == stage_id, "%s: ждали стадию '%s', получили '%s'" % [
		context, stage_id, actual
	])
	if actual == stage_id:
		var expected_title: String = str(_quest.get_current_stage_title())
		_expect(_quest.get_objective() == expected_title,
			"%s: цель '%s' не совпадает с заголовком стадии '%s'" % [
				context, _quest.get_objective(), expected_title
			])


func _stages_line() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for stage in _quest.get_stages():
		var mark := "x" if bool(stage.get("completed", false)) else " "
		if bool(stage.get("active", false)):
			mark = ">"
		parts.append("%s%s" % [mark, stage.get("id", "?")])
	return " ".join(parts)


func _wait_physics_frames(count: int) -> void:
	for _frame in count:
		await get_tree().physics_frame


func _log(message: String) -> void:
	_log_lines.append(message)
	print(message)


func _finish() -> void:
	if _failures.is_empty():
		_log(MARKER_OK)
		_log("проверок: %d" % _checks)
		_write_log()
		get_tree().quit(0)
		return
	_log("T16 GAMEPLAY SMOKE FAILED: %d из %d" % [_failures.size(), _checks])
	for failure in _failures:
		_log("  - %s" % failure)
	_write_log()
	push_error("T16 GAMEPLAY SMOKE FAILED: %d" % _failures.size())
	get_tree().quit(1)


func _write_log() -> void:
	var file := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[t16] не удалось записать %s (код %d)" % [
			LOG_PATH, FileAccess.get_open_error()
		])
		return
	file.store_string("\n".join(_log_lines) + "\n")
	file.close()
