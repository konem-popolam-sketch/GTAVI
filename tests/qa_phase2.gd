extends Node3D
## T22 QA PHASE 2 — независимая приёмка фазы 2 «Ночной смены».
##
## Не правит игру: только читает сцену/данные, гоняет диалоги, сейвы, звук.
## Запуск:
##   tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . \
##       tests/qa_phase2.tscn --log-file tools\qa_phase2.log
##
## Итог: строка "T22 QA PHASE 2 OK" (exit 0) или "T22 QA PHASE 2 FAILED: N"
## (exit 1). Полный список проверок — docs/qa/qa_phase2_results.json.
##
## Пользовательский каталог (user://) для прогона задаётся снаружи переменной
## APPDATA, чтобы не трогать настройки капитана.

const UiSettings = preload("res://scripts/ui/ui_settings.gd")

const MAIN_SCENE := "res://scenes/main.tscn"
const VOICE_DIR := "res://assets/audio/voice"
const MANIFEST_PATH := "res://scripts/dialogue/data/voice_manifest.json"
const SAVE_PATH := "user://save.json"
const OLD_FIXTURE := "user://qa_old_save.json"
const RESULTS_PATH := "res://docs/qa/qa_phase2_results.json"
const SHOTS_DIR := "res://docs/shots_phase2"
const LIVE_SHOTS_DIR := "res://docs/shots_final2"
const LETTERS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZабвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"

var checks: Array[Dictionary] = []
var failures: int = 0
var sections: Array[String] = []

var game: Node = null
var player: Player = null
var quest: Node = null
var dm: Node = null
var audio: Node = null
var hud: Control = null
var dialogue_ui: Control = null
var pause_menu: Control = null
var ui_layer: CanvasLayer = null

var _line_events: Array[Dictionary] = []
var _ended_events: Array[Dictionary] = []
var _start_count: int = 0


func _ready() -> void:
	await _run()


func _run() -> void:
	print("=== T22 QA PHASE 2 START ===")
	quest = get_node_or_null("/root/QuestState")
	dm = get_node_or_null("/root/DialogueManager")
	audio = get_node_or_null("/root/AudioManager")
	_check("autoloads", quest != null and dm != null and audio != null,
		"QuestState=%s DialogueManager=%s AudioManager=%s" % [quest != null, dm != null, audio != null])
	if quest == null or dm == null or audio == null:
		_finish()
		return
	quest.auto_save_enabled = false
	dm.line_changed.connect(_on_line_changed)
	dm.dialogue_ended.connect(_on_dialogue_ended)
	dm.dialogue_started.connect(_on_dialogue_started)

	await _load_game()
	await _check_scene_and_people()
	_check_quest_structure()
	await _check_hud()
	await _check_dialogue_data()
	await _check_dialogues_all()
	await _check_dialogue_input()
	await _check_dialogue_race()
	await _check_real_interaction()
	await _check_endings()
	await _check_voice_and_subtitles()
	await _check_audio()
	await _check_save()
	await _check_shots()
	_finish()


# --- Загрузка ---------------------------------------------------------------


func _load_game() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	_check("scene_load", packed != null, MAIN_SCENE)
	if packed == null:
		return
	game = packed.instantiate()
	add_child(game)
	await _frames(10)
	player = game.get_node_or_null("Player") as Player
	ui_layer = game.get_node_or_null("UI") as CanvasLayer
	hud = game.get_node_or_null("UI/HUD") as Control
	dialogue_ui = game.get_node_or_null("UI/DialogueUI") as Control
	pause_menu = game.get_node_or_null("UI/PauseMenu") as Control
	if game.has_method("start_fresh"):
		game.start_fresh()
	await _frames(5)
	_check("scene_player", player != null, "Player в main.tscn")
	_check("scene_world", game.get_node_or_null("World") != null, "World в main.tscn")
	_check("scene_ui", ui_layer != null and hud != null and dialogue_ui != null and pause_menu != null,
		"UI/HUD=%s DialogueUI=%s PauseMenu=%s" % [hud != null, dialogue_ui != null, pause_menu != null])
	if ui_layer != null:
		var last := ui_layer.get_child(ui_layer.get_child_count() - 1)
		_check("ui_pause_last", last == pause_menu, "последний ребёнок UI: %s" % last.name)


# --- Мир и люди (DoD 5, 6) --------------------------------------------------


func _check_scene_and_people() -> void:
	_section("scene_people")
	var npcs := get_tree().get_nodes_in_group("npc")
	_check("npc_count", npcs.size() == 6, "NPC в группе npc: %d (ждали 6)" % npcs.size())
	var expected := {
		"mila": "mila", "kostya": "kostya", "foreman": "foreman",
		"voice": "voice", "galya": "galya", "timur": "timur",
	}
	var seen: Dictionary = {}
	for npc in npcs:
		var dlg := str(npc.call("get_dialogue_id")) if npc.has_method("get_dialogue_id") else ""
		seen[dlg] = true
		_check("npc_%s_dialogue" % dlg, expected.has(dlg),
			"dialogue_id='%s' at %s" % [dlg, str((npc as Node3D).global_position)])
		var body: Node = npc.get_node_or_null("Body")
		_check("npc_%s_body" % dlg, body is MeshInstance3D, "Body=%s" % str(body))
		if body is MeshInstance3D:
			var parts := 0
			if body.has_method("get_part_count"):
				parts = int(body.call("get_part_count"))
			_check("npc_%s_parts" % dlg, parts >= 20, "сегментов тела: %d" % parts)
			var anim: AnimationPlayer = null
			if body.has_method("get_animation_player"):
				anim = body.call("get_animation_player") as AnimationPlayer
			if anim == null:
				anim = body.get_node_or_null("AnimationPlayer") as AnimationPlayer
			_check("npc_%s_animplayer" % dlg, anim != null, "AnimationPlayer")
			if anim != null:
				var has_walk := anim.has_animation("walk")
				var has_idle := anim.has_animation("idle")
				var has_run := anim.has_animation("run")
				_check("npc_%s_animations" % dlg, has_walk and has_idle and has_run,
					"idle=%s walk=%s run=%s" % [has_idle, has_walk, has_run])
				_check("npc_%s_playing" % dlg, anim.is_playing(),
					"играет=%s, текущая=%s" % [anim.is_playing(), anim.current_animation])
		var label := npc.get_node_or_null("NameLabel")
		_check("npc_%s_label" % dlg, label is Label3D, "NameLabel=%s" % str(label))
		# NPC стоит на полу, а не висит/утоплен: луч вниз мимо капсулы.
		var floor_hit := _ray_down(npc as Node3D, 1.6)
		_check("npc_%s_on_floor" % dlg, floor_hit.get("hit", false),
			"луч вниз: %s" % JSON.stringify(floor_hit))
		# Не вмурован в стену: 8 коротких лучей на высоте пояса.
		var stuck := 0
		for i in 8:
			var ang := float(i) * PI / 4.0
			if _ray(npc.global_position + Vector3(0, 1.0, 0),
					npc.global_position + Vector3(cos(ang), 1.0, sin(ang)) * 0.35, [npc]).get("hit", false):
				stuck += 1
		_check("npc_%s_clearance" % dlg, stuck == 0, "лучей в стену из 8: %d" % stuck)
	for key in expected.keys():
		_check("npc_present_%s" % key, seen.has(key), "NPC с dialogue_id '%s'" % key)

	# Пропсы.
	var props := game.get_node_or_null("Props")
	var prop_count := props.get_child_count() if props != null else 0
	_check("props_count", prop_count >= 10, "пропсов в Props: %d (DoD: >= 10)" % prop_count)

	# PBR-материалы: у поверхности есть albedo + normal texture.
	var textured: Dictionary = {}
	var mat_count := 0
	var textured_names: Array[String] = []
	var all_mats: Array[Material] = []
	for node in get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var mesh := (node as MeshInstance3D)
		if mesh.material_override != null:
			all_mats.append(mesh.material_override)
		if mesh.mesh == null:
			continue
		for surface in mesh.mesh.get_surface_count():
			var mat: Material = mesh.get_surface_override_material(surface)
			if mat == null:
				mat = mesh.mesh.surface_get_material(surface)
			if mat != null:
				all_mats.append(mat)
	for node in get_tree().root.find_children("*", "CSGPrimitive3D", true, false):
		var material: Material = (node as CSGPrimitive3D).material
		if material != null:
			all_mats.append(material)
	for mat in all_mats:
		if mat is StandardMaterial3D:
			var std := mat as StandardMaterial3D
			mat_count += 1
			if std.albedo_texture != null and std.normal_texture != null:
				var key := std.resource_path if not std.resource_path.is_empty() else str(std.get_instance_id())
				if not textured.has(key):
					textured[key] = true
					textured_names.append(key.get_file().get_basename())
	_check("pbr_materials", textured_names.size() >= 5,
		"материалов StandardMaterial3D: %d, с albedo+normal: %d %s" % [
			mat_count, textured_names.size(), textured_names
		])
	var expected_pbr := ["asphalt_pbr", "brick_red_pbr", "brick_grey_pbr", "concrete_pbr", "dock_planks_pbr", "metal_pbr"]
	var missing_pbr: Array[String] = []
	for expected_name in expected_pbr:
		if not textured_names.has(expected_name):
			missing_pbr.append(expected_name)
	_check("pbr_expected", missing_pbr.is_empty(), "нет PBR-материалов: %s" % [missing_pbr])
	_check("pbr_props", textured_names.has("dock_planks_pbr") and textured_names.has("metal_pbr"),
		"PBR-текстуры на пропсах (дерево/металл): %s" % [textured_names])
	var flat_surfaces: Array[String] = []
	for need in ["asphalt", "brick", "concrete"]:
		var found := false
		for name in textured_names:
			if name.contains(need):
				found = true
		if not found:
			flat_surfaces.append(need)
	_check("pbr_world_surfaces", flat_surfaces.is_empty(),
		"на асфальте/кирпиче/бетоне нет albedo+normal: %s" % [flat_surfaces])


func _check_quest_structure() -> void:
	_section("quest_structure")
	var stages: Array = quest.get_stages()
	_check("stages_10", stages.size() == 10, "стадий: %d" % stages.size())
	var acts: Dictionary = {}
	for stage in stages:
		acts[int((stage as Dictionary).get("act", 0))] = true
	_check("acts_3", acts.size() >= 3, "акты: %s" % [acts.keys()])
	_check("endings_3", int(quest.get("ENDING_TITLES").size()) == 3,
		"ENDING_TITLES: %s" % [quest.get("ENDING_TITLES").keys()])
	# 10 стадий покрывают 3 акта и финал.
	var ids: Array[String] = []
	for stage in stages:
		ids.append(str((stage as Dictionary).get("id", "")))
	_check("stages_chain", ids.has("deliver_package") and ids.has("final_choice") and ids.has("finished"),
		"цепочка стадий: %s" % [ids])


func _check_hud() -> void:
	_section("hud")
	if hud == null:
		return
	var overlay := hud.get_node_or_null("QuestLogOverlay") as Control
	var stages_box := hud.get_node_or_null("QuestLogOverlay/Center/Panel/Margin/VBox/StagesBox") as VBoxContainer
	_check("hud_questlog_nodes", overlay != null and stages_box != null,
		"QuestLogOverlay=%s StagesBox=%s" % [overlay != null, stages_box != null])
	if stages_box != null:
		hud.call("toggle_quest_log", true)
		await _frames(2)
		_check("hud_questlog_10", stages_box.get_child_count() == 10,
			"строк в журнале: %d" % stages_box.get_child_count())
		hud.call("toggle_quest_log", false)
	var objective := hud.get_node_or_null("ObjectivePanel/ObjectiveLabel") as Label
	_check("hud_objective", objective != null and objective.max_lines_visible == 2,
		"ObjectiveLabel max_lines_visible=%d" % (objective.max_lines_visible if objective != null else -1))


# --- Диалоги: данные (DoD 4, 5) ---------------------------------------------


func _check_dialogue_data() -> void:
	_section("dialogue_data")
	var ids: PackedStringArray = dm.get_dialogue_ids()
	_check("dialogues_17", ids.size() == 17, "диалогов: %d" % ids.size())
	var dialogues: Dictionary = dm.get("_dialogues")
	var nodes_total := 0
	var choice_nodes := 0
	var choices_total := 0
	var endings: Dictionary = {}
	var bad_links: Array[String] = []
	for dialogue_id in dialogues.keys():
		var dialogue: Dictionary = dialogues[dialogue_id]
		var nodes: Dictionary = dialogue.get("nodes", {})
		nodes_total += nodes.size()
		var start_id := str(dialogue.get("start", ""))
		if not nodes.has(start_id):
			bad_links.append("%s: нет стартового узла %s" % [dialogue_id, start_id])
		for node_id in nodes.keys():
			var node: Dictionary = nodes[node_id]
			var next_value: Variant = node.get("next", "")
			var next_id := "" if next_value == null else str(next_value)
			if not next_id.is_empty() and not nodes.has(next_id):
				bad_links.append("%s/%s: next=%s" % [dialogue_id, node_id, next_id])
			if int(node.get("ending", 0)) > 0:
				endings[int(node.get("ending"))] = str(node.get("ending_title", ""))
			var choices_variant: Variant = node.get("choices", [])
			if typeof(choices_variant) == TYPE_ARRAY and not (choices_variant as Array).is_empty():
				choice_nodes += 1
				for choice in (choices_variant as Array):
					choices_total += 1
					var choice_next_value: Variant = (choice as Dictionary).get("next", "")
					var choice_next := "" if choice_next_value == null else str(choice_next_value)
					if not choice_next.is_empty() and not nodes.has(choice_next):
						bad_links.append("%s/%s: choice next=%s" % [dialogue_id, node_id, choice_next])
	_check("dialogue_nodes_161", nodes_total == 161, "узлов: %d" % nodes_total)
	_check("dialogue_choices_13", choice_nodes == 13, "узлов с выбором: %d (вариантов %d)" % [choice_nodes, choices_total])
	_check("dialogue_links", bad_links.is_empty(), "битых ссылок: %d %s" % [bad_links.size(), bad_links.slice(0, 5)])
	_check("dialogue_endings", endings.size() == 3 and endings.has(1) and endings.has(2) and endings.has(3),
		"концовки: %s" % endings)


func _check_dialogues_all() -> void:
	_section("dialogues_run")
	var dialogues: Dictionary = dm.get("_dialogues")
	var failed_runs: Array[String] = []
	var runs := 0
	for dialogue_id in dialogues.keys():
		_line_events.clear()
		quest.reset()
		if not bool(dm.start(str(dialogue_id))):
			failed_runs.append("%s: не стартовал" % dialogue_id)
			continue
		var steps := 0
		var visited: Array[String] = []
		while bool(dm.is_active()) and steps < 300:
			visited.append(str(dm.get_current_node_id()))
			if bool(dm.has_choices()):
				dm.choose(0)
			else:
				dm.advance()
			steps += 1
		await _frames(1)
		runs += 1
		if dm.is_active():
			failed_runs.append("%s: не закрылся за %d шагов" % [dialogue_id, steps])
		if visited.is_empty():
			failed_runs.append("%s: не вошёл ни в один узел" % dialogue_id)
		# Субтитры (line_changed) должны совпадать с JSON по каждому узлу.
		var nodes: Dictionary = (dialogues[dialogue_id] as Dictionary).get("nodes", {})
		for event in _line_events:
			var node_id := str(event.get("node_id", ""))
			if nodes.has(node_id):
				var expected_text := str((nodes[node_id] as Dictionary).get("text", ""))
				if str(event.get("text", "")) != expected_text:
					failed_runs.append("%s/%s: субтитр != JSON" % [dialogue_id, node_id])
	_check("dialogues_all_closed", failed_runs.is_empty() and runs == 17,
		"пройдено %d/17, ошибок %d %s" % [runs, failed_runs.size(), failed_runs.slice(0, 8)])
	_check("dialogues_no_auto_reopen", not bool(dm.is_active()), "после прогона всех диалогов менеджер неактивен")


# --- Диалоги: ввод (DoD 2) --------------------------------------------------


func _check_dialogue_input() -> void:
	_section("dialogue_input")
	quest.reset()
	# 1. Esc закрывает.
	var esc_started_before := _start_count
	_check("esc_start", bool(dm.start("mila")), "start mila")
	await _frames(2)
	await _push_action("pause")
	await _frames(3)
	_check("esc_closes", not bool(dm.is_active()), "после Esc is_active=%s" % bool(dm.is_active()))
	# С t25 интерактор возвращается не мгновенно, а по кулдауну 0.35 с.
	var esc_interactor_back := false
	for _poll in 35:
		if _interactor_enabled():
			esc_interactor_back = true
			break
		await get_tree().create_timer(0.02).timeout
	_check("esc_interactor_back", esc_interactor_back, "интерактор вернулся после Esc (кулдаун)")
	_check("esc_restores_controls", _player_controls_ok(), "управление/интерактор после Esc")
	await get_tree().create_timer(1.0).timeout
	_check("esc_no_auto_reopen", not bool(dm.is_active()) and _start_count == esc_started_before + 1,
		"открытий после Esc: %d (ждали 1 — сам старт)" % (_start_count - esc_started_before))

	# 2. E закрывает последнюю реплику и не открывает диалог заново.
	quest.reset()
	_check("e_start", bool(dm.start("mila")), "start mila (E)")
	var started_before := _start_count
	while bool(dm.is_active()) and bool(dm.has_next_line()):
		dm.advance()
	await _frames(2)
	_check("e_at_last_line", bool(dm.is_active()) and not bool(dm.has_next_line()),
		"дошли до последней реплики: active=%s next=%s" % [dm.is_active(), dm.has_next_line()])
	# Озвучка последней реплики не должна «съесть» E: сначала дослушиваем
	# (stop_voice — как будто файл доиграл), затем E закрывает диалог.
	audio.stop_voice()
	await _frames(2)
	# Первое E во время «печатной машинки» только дорисовывает реплику.
	if dialogue_ui != null and bool(dialogue_ui.call("is_typing")):
		await _push_action("interact")
		await _frames(2)
		_check("e_first_press_completes", bool(dm.is_active()) and not bool(dialogue_ui.call("is_typing")),
			"первое E: active=%s typing=%s" % [dm.is_active(), dialogue_ui.call("is_typing")])
	await _push_action("interact")
	await _frames(3)
	_check("e_closes", not bool(dm.is_active()), "после E is_active=%s" % bool(dm.is_active()))
	_check("e_interactor_guard", not _interactor_enabled(), "интерактор погашен сразу после закрытия")
	# Через 0.35 с интерактор обязан вернуться (в headless ждём реальным таймером).
	var guard_restored := false
	for _poll in 70:
		if _interactor_enabled():
			guard_restored = true
			break
		await get_tree().create_timer(0.02).timeout
	_check("e_interactor_restored", guard_restored, "интерактор вернулся после кулдауна")
	await get_tree().create_timer(1.0).timeout
	_check("no_auto_reopen", not bool(dm.is_active()) and _start_count == started_before,
		"самих открытий после закрытия: %d" % (_start_count - started_before))

	# 3. На узле с выбором E игнорируется, Esc закрывает.
	quest.reset()
	_check("choice_start", bool(dm.start("finale")), "start finale")
	var guard := 0
	while bool(dm.is_active()) and not bool(dm.has_choices()) and guard < 64:
		dm.advance()
		guard += 1
	var node_before := str(dm.get_current_node_id())
	var choices_before: int = int(dm.get_choices().size())
	await _push_action("interact")
	await _frames(2)
	_check("choice_e_ignored", bool(dm.is_active()) and str(dm.get_current_node_id()) == node_before,
		"узел %s -> %s" % [node_before, dm.get_current_node_id()])
	_check("choice_count", choices_before >= 2 and choices_before <= 3, "вариантов: %d" % choices_before)
	await _push_action("pause")
	await _frames(3)
	_check("choice_esc_closes", not bool(dm.is_active()), "Esc на развилке закрыл диалог")


# --- Гонки кулдауна и поздних NPC (D2/D3 из t22) ---------------------------


func _check_dialogue_race() -> void:
	_section("dialogue_race")
	# Дать истечь старым таймерам кулдауна, чтобы стартовать с чистого состояния.
	await get_tree().create_timer(0.7).timeout
	var starts_before := _start_count
	var cycles := 20
	var intervals := [0.05, 0.07, 0.10, 0.13, 0.15]
	var measured: Array[float] = []
	var cycle_fail := ""
	for index in cycles:
		quest.reset()
		if not bool(dm.start("mila")):
			cycle_fail = "цикл %d: не стартовал" % index
			break
		var started_ms := Time.get_ticks_msec()
		await get_tree().create_timer(float(intervals[index % intervals.size()])).timeout
		await _push_action("pause")
		measured.append(float(Time.get_ticks_msec() - started_ms) / 1000.0)
		if bool(dm.is_active()):
			cycle_fail = "цикл %d: не закрылся" % index
			break
	_check("race_cycles", cycle_fail.is_empty(), cycle_fail)
	var min_cycle := 99.0
	var max_cycle := 0.0
	for value in measured:
		min_cycle = minf(min_cycle, value)
		max_cycle = maxf(max_cycle, value)
	_check("race_interval", min_cycle >= 0.04 and max_cycle <= 0.30,
		"цикл открыть→Esc: %.3f–%.3f с (%d циклов)" % [min_cycle, max_cycle, measured.size()])
	# После последнего закрытия: ровно один переход интерактора false→true за ~0.35 с.
	var transitions := 0
	var was_enabled := _interactor_enabled()
	var first_on_ms := -1
	var poll_start := Time.get_ticks_msec()
	for _poll in 80:
		var now_enabled := _interactor_enabled()
		if not was_enabled and now_enabled:
			transitions += 1
			if first_on_ms < 0:
				first_on_ms = Time.get_ticks_msec() - poll_start
		was_enabled = now_enabled
		await get_tree().create_timer(0.01).timeout
	_check("race_start_count", _start_count - starts_before == cycles,
		"открытий: %d (ждали %d)" % [_start_count - starts_before, cycles])
	_check("race_single_transition", transitions == 1,
		"переходов интерактора false→true после последнего закрытия: %d" % transitions)
	_check("race_transition_time", first_on_ms >= 250 and first_on_ms <= 500,
		"включение через %d мс (ждали ~350, допуск 250–500)" % first_on_ms)
	await get_tree().create_timer(1.0).timeout
	_check("race_no_auto_reopen",
		not bool(dm.is_active()) and _start_count - starts_before == cycles,
		"активен=%s, лишних открытий=%d" % [
			dm.is_active(), _start_count - starts_before - cycles
		])
	quest.reset()


# --- Реальное открытие через интерактор (DoD 2) -----------------------------


func _check_real_interaction() -> void:
	_section("interaction")
	if player == null:
		return
	quest.reset()
	var mila: Node3D = null
	for npc in get_tree().get_nodes_in_group("npc"):
		if str(npc.call("get_dialogue_id")) == "mila":
			mila = npc as Node3D
	if mila == null:
		_check("mila_found", false, "NPC Мила не найден")
		return
	player.teleport_to(mila.global_position + Vector3(0, 0.05, 2.2))
	player.rotation.y = 0.0
	await get_tree().create_timer(0.8).timeout
	await _frames(12)
	var interactor := player.get_interactor()
	_check("interactor_ready", interactor != null and bool(interactor.interaction_enabled),
		"интерактор включён=%s" % (interactor.interaction_enabled if interactor != null else false))
	var target = interactor.get_current_target() if interactor != null else null
	_check("mila_target", target == mila, "интерактор видит: %s" % str(target))
	await _push_action("interact")
	await _frames(6)
	_check("e_opens", bool(dm.is_active()) and str(dm.get_dialogue_id()) == "mila",
		"active=%s dialogue=%s" % [dm.is_active(), dm.get_dialogue_id()])
	await _push_action("pause")
	await _frames(3)
	_check("dialogue_closed_after", not bool(dm.is_active()), "диалог закрыт Esc")


# --- Три концовки (DoD 5) ---------------------------------------------------


func _check_endings() -> void:
	_section("endings")
	var titles := ["", "Молчание", "Голос", "Смена"]
	for index in 3:
		quest.reset()
		if index == 2:
			quest.set_flag("shift_log_seen")
			quest.set_flag("twin_box_found")
			quest.set_flag("foreman_cornered")
		var ok := bool(dm.start("finale"))
		if not ok:
			_check("ending_%d_start" % (index + 1), false, "finale не стартовал")
			continue
		var guard := 0
		while bool(dm.is_active()) and not bool(dm.has_choices()) and guard < 64:
			dm.advance()
			guard += 1
		var choices: int = int(dm.get_choices().size())
		_check("ending_%d_choice_visible" % (index + 1), choices >= index + 1,
			"вариантов: %d" % choices)
		dm.choose(index)
		guard = 0
		while bool(dm.is_active()) and guard < 64:
			if bool(dm.has_choices()):
				dm.choose(0)
			else:
				dm.advance()
			guard += 1
		await _frames(2)
		_check("ending_%d" % (index + 1),
			int(quest.get_ending_id()) == index + 1 and str(quest.get_ending_title()) == titles[index + 1],
			"ending_id=%d title='%s'" % [quest.get_ending_id(), quest.get_ending_title()])
		_check("ending_%d_finished" % (index + 1), bool(quest.is_finished()) and
			str(quest.get_current_stage_id()) == "finished", "стадия=%s" % quest.get_current_stage_id())
	quest.reset()


# --- Озвучка и субтитры (DoD 4) --------------------------------------------


func _check_voice_and_subtitles() -> void:
	_section("voice")
	var dialogues: Dictionary = dm.get("_dialogues")
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	_check("manifest_loaded", typeof(manifest) == TYPE_DICTIONARY and not manifest.is_empty(),
		"voice_manifest.json")
	var manifest_nodes := 0
	var manifest_mismatch: Array[String] = []
	var missing_files: Array[String] = []
	var empty_voice: Array[String] = []
	var too_short: Array[String] = []
	var covered := 0
	var letter_regex := RegEx.new()
	letter_regex.compile("[" + LETTERS + "]")
	for dialogue_id in dialogues.keys():
		var nodes: Dictionary = (dialogues[dialogue_id] as Dictionary).get("nodes", {})
		for node_id in nodes.keys():
			var text := str((nodes[node_id] as Dictionary).get("text", ""))
			var manifest_entry: Variant = null
			if typeof(manifest.get(dialogue_id, null)) == TYPE_DICTIONARY:
				manifest_entry = (manifest[dialogue_id] as Dictionary).get(node_id, null)
			if typeof(manifest_entry) == TYPE_DICTIONARY:
				manifest_nodes += 1
				if str((manifest_entry as Dictionary).get("text", "")) != text:
					manifest_mismatch.append("%s/%s" % [dialogue_id, node_id])
			var need_voice := letter_regex.search(text) != null
			var path := "%s/%s_%s.wav" % [VOICE_DIR, dialogue_id, node_id]
			var exists := FileAccess.file_exists(path)
			if need_voice and not exists:
				var entry_dict: Dictionary = manifest_entry if typeof(manifest_entry) == TYPE_DICTIONARY else {}
				var file := str(entry_dict.get("file", ""))
				if not file.is_empty() and FileAccess.file_exists("%s/%s" % [VOICE_DIR, file]):
					exists = true
			if need_voice:
				if not exists:
					missing_files.append("%s/%s" % [dialogue_id, node_id])
				else:
					covered += 1
					if path.ends_with(".wav") and FileAccess.file_exists(path):
						var length := float(audio.get_stream_length(path))
						if length <= 0.05:
							too_short.append("%s/%s (%.3f c)" % [dialogue_id, node_id, length])
			elif not exists:
				empty_voice.append("%s/%s" % [dialogue_id, node_id])
	_check("manifest_nodes_161", manifest_nodes == 161, "узлов в манифесте: %d" % manifest_nodes)
	_check("manifest_text_equal", manifest_mismatch.is_empty(),
		"расхождений текста: %d %s" % [manifest_mismatch.size(), manifest_mismatch.slice(0, 5)])
	_check("voice_coverage", missing_files.is_empty(),
		"без озвучки: %d %s (озвучено %d)" % [missing_files.size(), missing_files.slice(0, 5), covered])
	_check("voice_160", covered == 160, "озвученных узлов: %d (ждали 160)" % covered)
	_check("voice_lengths", too_short.is_empty(),
		"слишком коротких: %d %s" % [too_short.size(), too_short.slice(0, 5)])
	_check("voice_skip_dots", empty_voice.size() == 1 and empty_voice[0].contains("voice_03"),
		"узлы без букв: %s" % empty_voice)

	# Субтитр и озвучка: пока играет голос, E не обрывает реплику и не листает.
	quest.reset()
	_check("voice_dialogue", bool(dm.start("mila")), "start mila для проверки озвучки")
	await _frames(6)
	var text := str(dm.get_current_text())
	var node_id := str(dm.get_current_node_id())
	var playing := bool(audio.is_voice_playing())
	_check("voice_playing", playing, "is_voice_playing()=%s node=%s" % [playing, node_id])
	if dialogue_ui != null:
		var label := dialogue_ui.get_node_or_null("Panel/Margin/VBox/LineLabel") as Label
		_check("subtitle_text", label != null and label.text == text,
			"LineLabel='%s' vs '%s'" % [label.text if label != null else "?", text])
		dialogue_ui.call("complete_line")
	await _push_action("interact")
	await _frames(3)
	_check("voice_holds_line", bool(dm.is_active()) and str(dm.get_current_node_id()) == node_id,
		"после E при озвучке node=%s active=%s" % [dm.get_current_node_id(), dm.is_active()])
	if dialogue_ui != null:
		var label2 := dialogue_ui.get_node_or_null("Panel/Margin/VBox/LineLabel") as Label
		_check("subtitle_not_cut", label2 != null and label2.text == text and label2.visible,
			"субтитр жив: text='%s' visible=%s" % [label2.text if label2 != null else "?", label2.visible if label2 != null else false])
	# После конца озвучки E листает дальше.
	audio.stop_voice()
	await _push_action("interact")
	await _frames(3)
	_check("voice_advance_after_end", bool(dm.is_active()) and str(dm.get_current_node_id()) != node_id,
		"после stop_voice node=%s" % dm.get_current_node_id())
	await _push_action("pause")
	await _frames(3)


# --- Звук (DoD 3) -----------------------------------------------------------


func _check_audio() -> void:
	_section("audio")
	var buses: Array = audio.get_bus_table()
	_check("buses_5", buses.size() == 5, "шин: %d" % buses.size())
	for row in buses:
		var name := str((row as Dictionary).get("name", ""))
		_check("bus_%s" % name, AudioServer.get_bus_index(name) >= 0,
			"index=%d db=%.1f" % [AudioServer.get_bus_index(name), float((row as Dictionary).get("volume_db", 0.0))])
	audio.reset_bus_volumes()
	var defaults := {"Master": 0.0, "Music": -12.0, "SFX": -8.0, "Voice": -4.0, "Ambience": -14.0}
	var bad_defaults: Array[String] = []
	for name in defaults.keys():
		var db := float(audio.get_bus_volume_db(name))
		if absf(db - float(defaults[name])) > 0.6:
			bad_defaults.append("%s=%.1f (ждали %.1f)" % [name, db, defaults[name]])
	_check("bus_defaults", bad_defaults.is_empty(), "отклонения: %s" % [bad_defaults])

	var files: PackedStringArray = audio.list_audio_files()
	var bad_files: Array[String] = []
	var total := 0.0
	for path in files:
		var length := float(audio.get_stream_length(path))
		total += length
		if length <= 0.05:
			bad_files.append("%s (%.3f)" % [path, length])
	_check("audio_files_176", files.size() == 176, "файлов в assets/audio: %d" % files.size())
	_check("audio_files_readable", bad_files.is_empty(),
		"не читаются: %d %s; суммарно %.1f с" % [bad_files.size(), bad_files.slice(0, 5), total])

	# Окружение и музыка на старте.
	await _frames(30)
	var amb := str(audio.get_ambience_name())
	var music := str(audio.get_music_name())
	_check("ambience_start", amb != "", "окружение: '%s'" % amb)
	_check("music_start", music != "", "музыка: '%s'" % music)
	var amb_players: Array = audio.get("_amb_players")
	var amb_playing := false
	for player_node in amb_players:
		if (player_node as AudioStreamPlayer).playing:
			amb_playing = true
	_check("ambience_playing", amb_playing, "Ambience player.playing=%s" % amb_playing)

	# Шаги игрока: 3D-звук создаётся и играет.
	var before_children := 0
	for child in get_children():
		if child.name.begins_with("AudioOneShots"):
			before_children = child.get_child_count()
	audio.call("_emit_footstep", 4.0)
	await _frames(2)
	var one_shots: Node = null
	for child in get_children():
		if child.name.begins_with("AudioOneShots"):
			one_shots = child
	var after_children := one_shots.get_child_count() if one_shots != null else -1
	_check("footsteps", one_shots != null and after_children > before_children,
		"AudioOneShots: было %d, стало %d" % [before_children, after_children])

	# Громкость: audio.cfg.
	audio.set_bus_volume("SFX", 0.37)
	var cfg := ConfigFile.new()
	var cfg_ok := cfg.load("user://audio.cfg") == OK
	_check("audio_cfg", cfg_ok and absf(float(cfg.get_value("bus", "sfx", -1.0)) - 0.37) < 0.01,
		"audio.cfg sfx=%s" % (str(cfg.get_value("bus", "sfx", -1.0)) if cfg_ok else "нет файла"))
	audio.reload_audio_config()
	_check("audio_cfg_reload", absf(float(audio.get_bus_volume("SFX")) - 0.37) < 0.01,
		"после reload SFX=%.3f" % float(audio.get_bus_volume("SFX")))
	audio.reset_bus_volumes()

	# Громкость: settings.cfg через UiSettings и слайдер паузы.
	UiSettings.ensure_loaded()
	UiSettings.set_volume("Master", 0.42)
	var scfg := ConfigFile.new()
	var scfg_ok := scfg.load(UiSettings.CONFIG_PATH) == OK
	_check("settings_cfg", scfg_ok and absf(float(scfg.get_value("audio", "master", -1.0)) - 0.42) < 0.02,
		"settings.cfg master=%s" % (str(scfg.get_value("audio", "master", -1.0)) if scfg_ok else "нет файла"))
	UiSettings.reload_settings()
	_check("settings_cfg_reload", absf(UiSettings.get_volume("Master") - 0.42) < 0.02,
		"после reload Master=%.3f" % UiSettings.get_volume("Master"))
	if pause_menu != null:
		var slider := pause_menu.get_node_or_null("Dim/Center/Panel/Margin/VBox/MasterRow/MasterSlider") as HSlider
		_check("pause_slider", slider != null, "MasterSlider")
		if slider != null:
			slider.value = 37.0
			await _frames(2)
			var scfg2 := ConfigFile.new()
			var ok2 := scfg2.load(UiSettings.CONFIG_PATH) == OK
			_check("pause_slider_saves", ok2 and absf(float(scfg2.get_value("audio", "master", -1.0)) - 0.37) < 0.02,
				"settings.cfg master=%s" % (str(scfg2.get_value("audio", "master", -1.0)) if ok2 else "нет файла"))
			slider.value = 100.0
			await _frames(2)
	UiSettings.set_volume("Master", 1.0)
	UiSettings.save_settings()


# --- Сохранение (DoD 3) -----------------------------------------------------


func _check_save() -> void:
	_section("save")
	quest.reset()
	if player == null:
		return
	var save_position := Vector3(4.5, 0.1, 6.25)
	player.teleport_to(save_position)
	await _physics_frames(3)
	save_position = player.global_position
	quest.set_stage("talk_to_kostya")
	quest.set_flag("mila_confessed")
	quest.add_item("flashlight", "Фонарь")
	quest.set_item_state("package", {"state": "dropped", "position": [-2.0, -0.7, 36.8]})
	var saved := SaveSystem.save_game(player)
	_check("save_write", saved and FileAccess.file_exists(SAVE_PATH), "save_game=%s" % saved)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	var save_ok := typeof(parsed) == TYPE_DICTIONARY
	_check("save_json", save_ok, "save.json читается")
	if save_ok:
		var data: Dictionary = parsed
		var quest_data: Dictionary = data.get("quest", {})
		var position_data: Array = (data.get("player", {}) as Dictionary).get("position", [])
		_check("save_fields", int(data.get("version", 0)) == 1 and
			str(quest_data.get("stage_id", "")) == "talk_to_kostya" and
			bool((quest_data.get("flags", {}) as Dictionary).get("mila_confessed", false)) and
			(quest_data.get("inventory", []) as Array).size() == 1 and
			position_data.size() == 3,
			"version=%s stage=%s flags=%s inv=%s pos=%s" % [
				data.get("version"), quest_data.get("stage_id"),
				quest_data.get("flags"), quest_data.get("inventory"), position_data
			])

	# Мутируем и грузим.
	quest.reset()
	player.teleport_to(Vector3(0.0, 0.1, 10.0))
	await _frames(2)
	var loaded := SaveSystem.load_game(player)
	await _frames(3)
	_check("save_load", loaded, "load_game=%s" % loaded)
	_check("save_position", player.global_position.distance_to(save_position) < 0.15,
		"позиция %s vs %s" % [player.global_position, save_position])
	_check("save_stage", str(quest.get_current_stage_id()) == "talk_to_kostya",
		"стадия=%s" % quest.get_current_stage_id())
	_check("save_flag", bool(quest.has_flag("mila_confessed")), "mila_confessed")
	_check("save_item", bool(quest.has_item("flashlight")), "инвентарь=%s" % quest.get_items())
	_check("save_item_state", str(quest.get_item_state("package").get("state", "")) == "dropped",
		"item_state=%s" % quest.get_item_state("package"))
	_check("save_objective", str(quest.get_objective()) == str(quest.get_current_stage_title()),
		"цель='%s' титул='%s'" % [quest.get_objective(), quest.get_current_stage_title()])

	# Старый save.json фазы 1 (без stage_id/inventory) — миграция и загрузка.
	var old := {
		"version": 1,
		"saved_at": 1760000000,
		"player": {"position": [7.0, 0.1, 3.0], "rotation_y": 1.0},
		"quest": {
			"objective": "Проверь автоответчик у входа",
			"flags": {"package_delivered": true, "item_flashlight": true, "mila_warned": true},
			"ending_id": 0,
			"ending_title": "",
			"completed": false,
		},
	}
	var old_file := FileAccess.open(OLD_FIXTURE, FileAccess.WRITE)
	old_file.store_string(JSON.stringify(old, "\t"))
	old_file.close()
	_write_old_save(old)
	quest.reset()
	player.teleport_to(Vector3(0.0, 0.1, 10.0))
	var old_loaded := SaveSystem.load_game(player)
	await _frames(2)
	_check("old_save_load", old_loaded, "старый сейв загрузился=%s" % old_loaded)
	_check("old_save_position", player.global_position.distance_to(Vector3(7.0, 0.1, 3.0)) < 0.2,
		"позиция=%s" % player.global_position)
	_check("old_save_stage", str(quest.get_current_stage_id()) == "check_answerphone",
		"стадия=%s" % quest.get_current_stage_id())
	_check("old_save_objective", str(quest.get_objective()) == "Проверь автоответчик у входа",
		"цель='%s'" % quest.get_objective())
	_check("old_save_inventory", bool(quest.has_item("flashlight")), "предметы=%s" % quest.get_items())
	_check("old_save_flags", bool(quest.has_flag("mila_warned")), "флаги сохранены")

	# Старый сейв с концовкой — finished.
	old["quest"] = {
		"objective": "История завершена",
		"flags": {"package_delivered": true, "ending_voice": true},
		"ending_id": 2,
		"ending_title": "Голос",
		"completed": true,
	}
	var old_file2 := FileAccess.open(OLD_FIXTURE, FileAccess.WRITE)
	old_file2.store_string(JSON.stringify(old, "\t"))
	old_file2.close()
	_write_old_save(old)
	quest.reset()
	SaveSystem.load_game(player)
	await _frames(2)
	_check("old_save_ending", int(quest.get_ending_id()) == 2 and bool(quest.is_finished()) and
		str(quest.get_current_stage_id()) == "finished",
		"ending=%d completed=%s stage=%s" % [quest.get_ending_id(), quest.is_finished(), quest.get_current_stage_id()])


# --- Скриншоты (DoD 7) ------------------------------------------------------


func _check_shots() -> void:
	_section("shots")
	var paths := [SHOTS_DIR, LIVE_SHOTS_DIR]
	for dir_path in paths:
		var files: PackedStringArray = []
		var dir := DirAccess.open(dir_path)
		if dir != null:
			for file in DirAccess.get_files_at(dir_path):
				if file.to_lower().ends_with(".png"):
					files.append(file)
		var bad: Array[String] = []
		for file in files:
			var path := "%s/%s" % [dir_path, file]
			var bytes := FileAccess.get_file_as_bytes(path)
			if bytes.size() < 30000:
				bad.append("%s (%d B)" % [file, bytes.size()])
		_check("shots_count_%s" % dir_path.get_file(), files.size() >= 3,
			"%s: PNG %d" % [dir_path, files.size()])
		_check("shots_valid_%s" % dir_path.get_file(), bad.is_empty(),
			"мелких/битых: %d %s" % [bad.size(), bad.slice(0, 5)])
	# Кадры QA-репро лежат отдельно.
	var qa_dir := DirAccess.open("res://docs/qa")
	var qa_png := 0
	if qa_dir != null:
		for file in DirAccess.get_files_at("res://docs/qa"):
			if file.to_lower().ends_with(".png"):
				qa_png += 1
	_check("qa_shots", qa_png >= 2, "docs/qa PNG: %d" % qa_png)


# --- Утилиты ----------------------------------------------------------------


func _section(name: String) -> void:
	sections.append(name)
	print("[qa] --- %s ---" % name)


func _check(id: String, ok: bool, detail: String = "") -> void:
	checks.append({"id": id, "ok": ok, "detail": detail})
	if ok:
		return
	failures += 1
	print("[qa][FAIL] %s: %s" % [id, detail])


func _frames(count: int) -> void:
	for _index in count:
		await get_tree().process_frame


func _physics_frames(count: int) -> void:
	for _index in count:
		await get_tree().physics_frame


func _push_action(action: String) -> void:
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	await get_tree().process_frame
	var release := InputEventAction.new()
	release.action = action
	release.pressed = false
	Input.parse_input_event(release)
	await get_tree().process_frame


func _player_controls_ok() -> bool:
	if player == null:
		return false
	var controls := bool(player.get("controls_enabled"))
	return controls and _interactor_enabled()


func _interactor_enabled() -> bool:
	if player == null:
		return false
	var interactor := player.get_interactor()
	return interactor != null and bool(interactor.interaction_enabled)


func _ray_down(node: Node3D, length: float) -> Dictionary:
	var from_pos := node.global_position + Vector3(0.0, 0.05, 0.0)
	var exclusions: Array = []
	if node is CollisionObject3D:
		exclusions.append((node as CollisionObject3D).get_rid())
	return _ray(from_pos, from_pos - Vector3(0.0, length, 0.0), exclusions)


func _ray(from_pos: Vector3, to_pos: Vector3, exclusions: Array = []) -> Dictionary:
	var space := get_viewport().world_3d.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from_pos, to_pos, 1)
	if not exclusions.is_empty():
		query.exclude = exclusions
	var result := space.intersect_ray(query)
	if result.is_empty():
		return {"hit": false}
	return {
		"hit": true,
		"collider": str((result.get("collider") as Node).get_path()) if result.get("collider") is Node else "",
		"position": str(result.get("position", Vector3.ZERO)),
	}


func _on_line_changed(dialogue_id: String, node_id: String, _speaker: String, text: String, choices: Array) -> void:
	_line_events.append({
		"dialogue_id": dialogue_id,
		"node_id": node_id,
		"text": text,
		"choices": choices.size(),
	})


func _on_dialogue_ended(dialogue_id: String, ending_id: int) -> void:
	_ended_events.append({"dialogue_id": dialogue_id, "ending_id": ending_id})


func _on_dialogue_started(_dialogue_id: String, _npc: Node) -> void:
	_start_count += 1


func _write_old_save(data: Dictionary) -> void:
	var raw := JSON.stringify(data, "\t")
	for path in [SAVE_PATH, OLD_FIXTURE]:
		var file := FileAccess.open(str(path), FileAccess.WRITE)
		if file != null:
			file.store_string(raw)
			file.close()


func _finish() -> void:
	var passed := checks.size() - failures
	var summary := {
		"checks": checks.size(),
		"passed": passed,
		"failed": failures,
		"failures": checks.filter(func(entry: Dictionary) -> bool: return not bool(entry.get("ok", false))),
		"results": checks,
	}
	var dir := DirAccess.open("res://docs/qa")
	if dir == null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/qa"))
	var file := FileAccess.open(RESULTS_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(summary, "\t"))
		file.close()
	if failures == 0:
		print("T22 QA PHASE 2 OK (%d проверок)" % checks.size())
		get_tree().quit(0)
		return
	print("T22 QA PHASE 2 FAILED: %d из %d" % [failures, checks.size()])
	for entry in checks:
		if not bool(entry.get("ok", false)):
			print("  - %s: %s" % [entry.get("id"), entry.get("detail")])
	get_tree().quit(1)
