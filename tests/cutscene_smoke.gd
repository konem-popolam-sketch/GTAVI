extends Node3D
## cutscene_smoke — приёмочный смоук системы катсцен (t38).
##
## 12+ проверок:
##   1) данные всех четырёх катсцен грузятся без ошибок;
##   2) start() блокирует управление игрока и интерактор;
##   3) CutsceneCamera становится current, камера игрока — нет;
##   4) камера реально едет по таймлайну;
##   5) субтитр появляется из JSON диалога (текст и спикер);
##   6) HUD и подписи NPC скрыты на время сцены;
##   7) скип завершает сцену и возвращает управление/камеру;
##   8) после скипа игрок стоит в конечной точке сцены;
##   9) флаг cut_prologue_seen поставлен и сохранён;
##   10) повторный start() без force не запускает просмотренную сцену;
##   11) новая сцена с autostart не перезапускает пролог при загруженном сейве;
##   12) сцена доигрывает по таймеру и ставит cut_box_seen;
##   13) триггер по флагу twin_box_found запускает cut_box и не повторяется.
##
## Запуск:
##   godot --headless --path . --quit-after 3000 res://tests/cutscene_smoke.tscn
##   godot --path . res://tests/cutscene_smoke.tscn -- --shots   (2 кадра)

const CUTSCENE_DATA := preload("res://scripts/game/cutscene_data.gd")
const SAVE_SYSTEM := preload("res://scripts/game/save_system.gd")
const STAGE_SCENE := preload("res://scenes/game/cutscene_stage.tscn")

@onready var stage: CutscenePlayer = $CutsceneStage
@onready var player: Player = $Player
@onready var mila: NPC = $Npcs/Mila
@onready var hud: Control = $UI/HUD

var _passed: int = 0
var _failed: int = 0
var _checks: int = 0


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if OS.get_cmdline_user_args().has("--shots"):
		await _run_shots()
		return
	await _run_smoke()


func _run_smoke() -> void:
	print("[t38] CUTSCENE SMOKE START")

	# 1. Данные.
	var errors := CUTSCENE_DATA.get_errors()
	_check("данные катсцен", CUTSCENE_DATA.get_ids().size() == 4 and errors.is_empty(),
		"ids=%d, errors=%s" % [CUTSCENE_DATA.get_ids().size(), str(errors)])
	for cutscene_id in ["cut_prologue", "cut_box", "cut_weapon", "cut_weapon_alt"]:
		_check("катсцена %s загружена" % cutscene_id,
			CUTSCENE_DATA.has_cutscene(cutscene_id), "")

	# 2-3. Старт блокирует управление, камера переключена.
	var started := stage.start("cut_prologue", true)
	_check("start(cut_prologue)", started and stage.is_playing(), "started=%s" % str(started))
	_check("управление игрока выключено", not player.controls_enabled, "")
	_check("интерактор выключен",
		not player.get_interactor().interaction_enabled, "")
	var cut_camera := stage.get_cutscene_camera()
	_check("cutscene camera current",
		cut_camera.current and not player.get_camera().current, "")

	# 6. HUD и подписи NPC скрыты.
	var name_label := mila.find_child("NameLabel", true, false) as Label3D
	_check("HUD скрыт", not hud.visible, "")
	_check("подпись NPC скрыта", name_label != null and not name_label.visible, "")

	# 4. Камера едет.
	var start_camera := cut_camera.global_position
	await get_tree().create_timer(1.15).timeout
	var moved := start_camera.distance_to(cut_camera.global_position)
	_check("камера едет", moved > 0.04, "сдвиг %.3f м" % moved)

	# 5. Субтитр из JSON (реплика cp_01 идёт с 1.0 с).
	var subtitle: PanelContainer = stage.get_node("UI/SubtitlePanel")
	var subtitle_text: Label = stage.get_node("UI/SubtitlePanel/Margin/VBox/SubtitleLabel")
	var speaker: Label = stage.get_node("UI/SubtitlePanel/Margin/VBox/SpeakerLabel")
	_check("субтитр виден", subtitle.visible, "t=%.2f" % stage.get_time())
	_check("текст реплики из JSON",
		subtitle_text.text == "Двадцать два сорок. Смена." and speaker.text == "Нил",
		"«%s» / %s" % [subtitle_text.text, speaker.text])

	# 7-9. Скип, возврат управления, конечная позиция, флаг.
	var skipped := stage.skip()
	await get_tree().create_timer(0.25).timeout
	_check("скип сработал", skipped and not stage.is_playing(), "")
	_check("управление вернулось", player.controls_enabled, "")
	_check("интерактор вернулся", player.get_interactor().interaction_enabled, "")
	_check("камера игрока снова current",
		player.get_camera().current and not cut_camera.current, "")
	var end_position := player.global_position
	_check("игрок в конечной точке",
		end_position.distance_to(Vector3(-3.0, 0.1, -6.4)) < 0.25, str(end_position))
	_check("флаг cut_prologue_seen",
		QuestState.has_flag("cut_prologue_seen"), "")
	_check("HUD вернулся", hud.visible, "")
	_check("подпись NPC вернулась", name_label != null and name_label.visible, "")

	# 10. Повторный запуск без force.
	_check("повторный start не запускает",
		not stage.start("cut_prologue") and not stage.is_playing(), "")

	# 11. Загрузка сейва с флагом: новый узел с autostart не играет пролог.
	SAVE_SYSTEM.save_game(player)
	var second_stage: CutscenePlayer = STAGE_SCENE.instantiate()
	second_stage.autostart_enabled = true
	second_stage.debug_logging = false
	add_child(second_stage)
	await get_tree().create_timer(0.6).timeout
	_check("загрузка с флагом не перезапускает пролог",
		not second_stage.is_playing(), "pending=%s" % second_stage.get_pending_id())

	# 12. Таймер: cut_box доигрывает и ставит флаг.
	var timed_start := stage.start("cut_box", true)
	_check("start(cut_box)", timed_start and stage.is_playing(), "")
	await get_tree().create_timer(10.35).timeout
	_check("cut_box завершилась по таймеру", not stage.is_playing(), "")
	_check("флаг cut_box_seen", QuestState.has_flag("cut_box_seen"), "")

	# 13. Триггер по флагу twin_box_found.
	QuestState.reset()
	second_stage.play_prologue_on_new_game = false
	second_stage.autostart_enabled = true
	QuestState.set_flag("twin_box_found", true)
	await get_tree().create_timer(0.6).timeout
	_check("триггер twin_box_found запустил cut_box",
		second_stage.is_playing() and second_stage.get_current_id() == "cut_box",
		"id=%s" % second_stage.get_current_id())
	second_stage.skip()
	await get_tree().create_timer(0.2).timeout
	second_stage._maybe_auto_start()
	await get_tree().create_timer(0.3).timeout
	_check("повторный триггер не запускает cut_box",
		not second_stage.is_playing(), "")

	# Уборка за собой, чтобы сцена не осталась в cut-камере.
	if stage.is_playing():
		stage.skip()
	second_stage.queue_free()
	await get_tree().process_frame

	print("[t38] проверок %d, пройдено %d, провалено %d" % [_checks, _passed, _failed])
	if _failed == 0:
		print("CUTSCENE SMOKE OK")
	else:
		push_error("CUTSCENE SMOKE FAIL")
		get_tree().quit(1)


func _run_shots() -> void:
	if DisplayServer.get_name() == "headless":
		print("[t38] --shots требует окно (не headless)")
		get_tree().quit(1)
		return
	var shots_dir := ProjectSettings.globalize_path("res://docs/shots_cut")
	DirAccess.make_dir_recursive_absolute(shots_dir)
	var started := stage.start("cut_prologue", true)
	if not started:
		push_error("[t38] shots: cut_prologue не стартовала")
		get_tree().quit(1)
		return
	await get_tree().create_timer(2.0).timeout
	await _capture_frame("%s/prologue_01.png" % shots_dir)
	await get_tree().create_timer(3.6).timeout
	await _capture_frame("%s/prologue_02.png" % shots_dir)
	print("[t38] кадры катсцены: prologue_01.png, prologue_02.png")
	get_tree().quit(0)


func _capture_frame(path: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error == OK:
		print("[t38] кадр сохранён: %s" % path)
	else:
		push_error("[t38] не удалось сохранить кадр: %s (%d)" % [path, error])


func _check(label: String, condition: bool, detail: String) -> void:
	_checks += 1
	if condition:
		_passed += 1
		print("[t38] OK   %s%s" % [label, (" — " + detail) if not detail.is_empty() else ""])
	else:
		_failed += 1
		push_error("[t38] FAIL %s%s" % [label, (" — " + detail) if not detail.is_empty() else ""])
