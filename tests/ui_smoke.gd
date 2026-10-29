extends Node
## T17 UI SMOKE — headless-проверка интерфейса «Ночной смены» (HUD v2, субтитры
## с typewriter, пауза и настройки громкости).
##
## Запуск:
##   tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . \
##       tests/ui_smoke.tscn --log-file tools\t17_ui_smoke.log
##
## Что проверяет:
##   1) HUD/HUD v2: цель, счётчик, подсказка, скрытие на паузе и в диалоге,
##      квест-лог по Tab;
##   2) DialogueUI: скрыт без диалога, typewriter не падает на пустом тексте,
##      complete_line() дорисовывает реплику;
##   3) PauseMenu: open ставит get_tree().paused = true и прячет HUD,
##      close снимает паузу и возвращает HUD; Esc не открывает паузу в диалоге;
##   4) слайдеры пишут громкость в user://settings.cfg и она читается обратно;
##   5) три ступени шрифта диалога и высокий контраст применяются.
##
## Успех — строка "T17 UI SMOKE OK" и код возврата 0; провал — "T17 UI SMOKE FAIL: …".

const UiSettings = preload("res://scripts/ui/ui_settings.gd")
const HUD_SCENE := "res://ui/hud.tscn"
const DIALOGUE_SCENE := "res://ui/dialogue.tscn"
const PAUSE_SCENE := "res://ui/pause_menu.tscn"

var _failures: Array[String] = []
var _hud: Control = null
var _dialogue: Control = null
var _menu: Control = null


func _ready() -> void:
	await _run()


func _run() -> void:
	print("[smoke] старт T17 UI SMOKE")
	UiSettings.ensure_loaded()
	# Тест не должен зависеть от того, что игрок выключил подсказки в прошлый раз.
	UiSettings.set_hints_visible(true, false)
	await _spawn_ui()
	_check_hud_initial()
	_check_quest_log()
	_check_pause_toggle()
	await _check_settings_persistence()
	await _check_dialogue_ui()
	_check_font_accessibility()
	await _check_dialogue_blocks_pause()
	_cleanup()
	_report()


# --- Подготовка -------------------------------------------------------------


func _spawn_ui() -> void:
	var hud_packed := load(HUD_SCENE) as PackedScene
	if hud_packed == null:
		_failures.append("не загружается %s" % HUD_SCENE)
	else:
		_hud = hud_packed.instantiate() as Control
		add_child(_hud)
	var dialogue_packed := load(DIALOGUE_SCENE) as PackedScene
	if dialogue_packed == null:
		_failures.append("не загружается %s" % DIALOGUE_SCENE)
	else:
		_dialogue = dialogue_packed.instantiate() as Control
		add_child(_dialogue)
	var pause_packed := load(PAUSE_SCENE) as PackedScene
	if pause_packed == null:
		_failures.append("не загружается %s" % PAUSE_SCENE)
	else:
		_menu = pause_packed.instantiate() as Control
		add_child(_menu)
	await get_tree().process_frame
	await get_tree().process_frame
	print("[smoke] сцены созданы: HUD=%s, DialogueUI=%s, PauseMenu=%s" % [
		str(_hud != null), str(_dialogue != null), str(_menu != null)
	])


# --- Проверки ---------------------------------------------------------------


func _check_hud_initial() -> void:
	if _hud == null:
		return
	var objective_label := _hud.get_node_or_null("ObjectivePanel/ObjectiveLabel") as Label
	if objective_label == null:
		_failures.append("в HUD нет ObjectivePanel/ObjectiveLabel")
	elif not objective_label.text.begins_with("ЦЕЛЬ:"):
		_failures.append("HUD цель = '%s' (ждали префикс «ЦЕЛЬ:»)" % objective_label.text)
	else:
		print("[smoke] HUD цель: %s" % objective_label.text)
	if objective_label != null and objective_label.max_lines_visible != 2:
		_failures.append("HUD цель не ограничена двумя строками (max_lines_visible=%d)" % (
			objective_label.max_lines_visible
		))
	var counter := _hud.get_node_or_null("CounterPanel/CounterLabel") as Label
	if counter == null:
		_failures.append("в HUD нет CounterPanel/CounterLabel")
	elif not counter.text.begins_with("НАЙДЕНО"):
		_failures.append("HUD счётчик = '%s'" % counter.text)
	else:
		print("[smoke] HUD счётчик: %s" % counter.text)
	_hud.call("show_hint", "E — взять")
	var hint_panel := _hud.get_node_or_null("HintPanel") as Control
	var hint_label := _hud.get_node_or_null("HintPanel/HintLabel") as Label
	if hint_panel == null or not hint_panel.visible:
		_failures.append("подсказка HUD не появилась после show_hint()")
	elif hint_label == null or hint_label.text != "E — взять":
		_failures.append("подсказка HUD = '%s'" % (hint_label.text if hint_label != null else "?"))
	else:
		print("[smoke] подсказка: %s" % hint_label.text)
	if _hud.call("is_title_open"):
		_failures.append("HUD считает титул открытым в тестовой сцене")


func _check_quest_log() -> void:
	if _hud == null:
		return
	var overlay := _hud.get_node_or_null("QuestLogOverlay") as Control
	var stages := _hud.get_node_or_null("QuestLogOverlay/Center/Panel/Margin/VBox/StagesBox") as VBoxContainer
	if overlay == null or stages == null:
		_failures.append("в HUD нет QuestLogOverlay или StagesBox")
		return
	_hud.call("toggle_quest_log", true)
	if not overlay.visible:
		_failures.append("квест-лог не открылся по toggle_quest_log(true)")
	if stages.get_child_count() == 0:
		_failures.append("квест-лог открылся без стадий")
	else:
		print("[smoke] квест-лог: стадий %d" % stages.get_child_count())
	_hud.call("toggle_quest_log", false)
	if overlay.visible:
		_failures.append("квест-лог не закрылся по toggle_quest_log(false)")


func _check_pause_toggle() -> void:
	if _menu == null or _hud == null:
		return
	_menu.call("open_menu")
	if not bool(_menu.call("is_open")):
		_failures.append("PauseMenu не открылся")
	if not get_tree().paused:
		_failures.append("PauseMenu не поставил get_tree().paused = true")
	if _hud.visible:
		_failures.append("HUD остался видимым на паузе")
	print("[smoke] пауза: открыта, tree.paused=%s, HUD visible=%s" % [
		str(get_tree().paused), str(_hud.visible)
	])
	_menu.call("close_menu")
	if bool(_menu.call("is_open")):
		_failures.append("PauseMenu не закрылся")
	if get_tree().paused:
		_failures.append("PauseMenu не снял get_tree().paused")
	if not _hud.visible:
		_failures.append("HUD не вернулся после закрытия паузы")
	print("[smoke] пауза: закрыта, tree.paused=%s, HUD visible=%s" % [
		str(get_tree().paused), str(_hud.visible)
	])


func _check_settings_persistence() -> void:
	if _menu == null:
		return
	var original_master := UiSettings.get_volume("Master")
	var original_sfx := UiSettings.get_volume("SFX")
	var master_slider := _menu.get_node_or_null(
		"Dim/Center/Panel/Margin/VBox/MasterRow/MasterSlider"
	) as HSlider
	var sfx_slider := _menu.get_node_or_null(
		"Dim/Center/Panel/Margin/VBox/SfxRow/SfxSlider"
	) as HSlider
	if master_slider == null or sfx_slider == null:
		_failures.append("в PauseMenu нет слайдеров Master/SFX")
		return
	master_slider.value = 42.0
	sfx_slider.value = 37.0
	await get_tree().process_frame
	var config := ConfigFile.new()
	if config.load(UiSettings.CONFIG_PATH) != OK:
		_failures.append("user://settings.cfg не читается после движения слайдеров")
	else:
		var saved_master := float(config.get_value("audio", "master", -1.0))
		var saved_sfx := float(config.get_value("audio", "sfx", -1.0))
		if absf(saved_master - 0.42) > 0.02:
			_failures.append("в settings.cfg master=%.3f, ждали ~0.42" % saved_master)
		if absf(saved_sfx - 0.37) > 0.02:
			_failures.append("в settings.cfg sfx=%.3f, ждали ~0.37" % saved_sfx)
		print("[smoke] settings.cfg: master=%.3f, sfx=%.3f" % [saved_master, saved_sfx])
	# Перечитываем с диска — значения должны вернуться те же.
	UiSettings.reload_settings()
	if absf(UiSettings.get_volume("Master") - 0.42) > 0.02:
		_failures.append("после reload_settings Master=%.3f" % UiSettings.get_volume("Master"))
	if absf(UiSettings.get_volume("SFX") - 0.37) > 0.02:
		_failures.append("после reload_settings SFX=%.3f" % UiSettings.get_volume("SFX"))
	# Возвращаем как было, чтобы не портить пользовательский конфиг.
	UiSettings.set_volume("Master", original_master, false)
	UiSettings.set_volume("SFX", original_sfx, false)
	UiSettings.save_settings()
	master_slider.set_value_no_signal(roundf(original_master * 100.0))
	sfx_slider.set_value_no_signal(roundf(original_sfx * 100.0))
	print("[smoke] настройки прочитаны после reload: Master=%.2f, SFX=%.2f" % [
		UiSettings.get_volume("Master"), UiSettings.get_volume("SFX")
	])


func _check_dialogue_ui() -> void:
	if _dialogue == null:
		return
	if _dialogue.visible:
		_failures.append("DialogueUI виден без активного диалога")
	# Пустой текст не должен ронять typewriter.
	_dialogue.call("_start_typing", "")
	if bool(_dialogue.call("is_typing")):
		_failures.append("typewriter крутится на пустом тексте")
	var line_label := _dialogue.get_node_or_null("Panel/Margin/VBox/LineLabel") as Label
	if line_label != null and line_label.visible_characters != -1:
		_failures.append("после пустого текста visible_characters=%d" % line_label.visible_characters)
	# Обычный текст: сперва печатается, затем complete_line() показывает всё.
	_dialogue.call("_start_typing", "Нил. Ты сегодня поздно.")
	if not bool(_dialogue.call("is_typing")):
		_failures.append("typewriter не запустился на обычном тексте")
	elif line_label != null and line_label.visible_characters >= 0:
		print("[smoke] typewriter: старт с %d видимых символов" % line_label.visible_characters)
	await get_tree().process_frame
	await get_tree().process_frame
	var partial := line_label.visible_characters if line_label != null else -2
	_dialogue.call("complete_line")
	if bool(_dialogue.call("is_typing")):
		_failures.append("complete_line() не остановил typewriter")
	if line_label != null and line_label.visible_characters != -1:
		_failures.append("complete_line() не показал текст целиком")
	print("[smoke] typewriter: после 2 кадров %d символов, complete_line → весь текст" % partial)
	# Подсказка «Esc — выйти» на месте.
	var continue_label := _dialogue.get_node_or_null("Panel/Margin/VBox/ContinueLabel") as Label
	if continue_label != null and not continue_label.text.contains("Esc"):
		_failures.append("в подсказке диалога нет «Esc — выйти»: '%s'" % continue_label.text)
	# Синхронизация с озвучкой: без файлов озвучки ветка «держать реплику» спит,
	# но проверяем, что она не срабатывает ложно и не падает без звука.
	if bool(_dialogue.call("_voice_playing")):
		_failures.append("озвучка считается играющей при пустом assets/audio/voice")
	if bool(_dialogue.call("_voice_hold_expired")):
		_failures.append("ожидание озвучки истекло сразу после старта реплики")
	else:
		print("[smoke] озвучка: is_voice_playing()=false — субтитры идут сами")


func _check_font_accessibility() -> void:
	if _dialogue == null or _hud == null:
		return
	var line_label := _dialogue.get_node_or_null("Panel/Margin/VBox/LineLabel") as Label
	var hint_label := _hud.get_node_or_null("HintPanel/HintLabel") as Label
	if line_label == null or hint_label == null:
		return
	var original_step := UiSettings.get_dialogue_font_step()
	var original_contrast := UiSettings.high_contrast
	UiSettings.set_dialogue_font_step(2, false)
	_dialogue.call("apply_settings")
	var big := line_label.get_theme_font_size("font_size")
	UiSettings.set_dialogue_font_step(0, false)
	_dialogue.call("apply_settings")
	var small := line_label.get_theme_font_size("font_size")
	if big <= small:
		_failures.append("размер шрифта не растёт: %d → %d" % [small, big])
	else:
		print("[smoke] шрифт диалога: %d → %d px (3 ступени)" % [small, big])
	UiSettings.set_high_contrast(false, false)
	_hud.call("apply_settings")
	var outline_off := hint_label.get_theme_constant("outline_size")
	UiSettings.set_high_contrast(true, false)
	_hud.call("apply_settings")
	var outline_on := hint_label.get_theme_constant("outline_size")
	if outline_on <= outline_off:
		_failures.append("высокий контраст не включает обводку подсказки (%d → %d)" % [
			outline_off, outline_on
		])
	else:
		print("[smoke] контраст подсказок: обводка %d → %d" % [outline_off, outline_on])
	UiSettings.set_dialogue_font_step(original_step, false)
	UiSettings.high_contrast = original_contrast
	_dialogue.call("apply_settings")
	_hud.call("apply_settings")
	UiSettings.save_settings()


func _check_dialogue_blocks_pause() -> void:
	if _menu == null:
		return
	var manager := get_node_or_null("/root/DialogueManager")
	if manager == null:
		_failures.append("нет автолоада DialogueManager")
		return
	var ids: PackedStringArray = manager.call("get_dialogue_ids")
	if ids.is_empty():
		print("[smoke] диалогов нет — проверка конфликта Esc пропущена")
		return
	var dialogue_id := "mila" if ids.has("mila") else str(ids[0])
	if not bool(manager.call("start", dialogue_id, null)):
		_failures.append("DialogueManager.start('%s') вернул false" % dialogue_id)
		return
	await get_tree().process_frame
	if not bool(_menu.call("_pause_blocked")):
		_failures.append("Esc в диалоге не заблокирован: пауза открылась бы поверх диалога")
	else:
		print("[smoke] Esc в диалоге: пауза заблокирована (диалог закрывает DialogueManager)")
	manager.call("close")
	await get_tree().process_frame
	await get_tree().process_frame
	if _hud != null:
		var objective_panel := _hud.get_node_or_null("ObjectivePanel") as Control
		if objective_panel != null and not objective_panel.visible:
			_failures.append("после закрытия диалога цель HUD не вернулась")
	if not _hud.visible:
		_failures.append("после закрытия диалога HUD остался скрыт")


# --- Итог -------------------------------------------------------------------


func _cleanup() -> void:
	get_tree().paused = false
	if _menu != null and bool(_menu.call("is_open")):
		_menu.call("close_menu")
	UiSettings.save_settings()


func _report() -> void:
	if _failures.is_empty():
		print("[smoke] HUD v2, субтитры, пауза, settings.cfg и доступность — в порядке")
		print("T17 UI SMOKE OK")
		get_tree().quit(0)
		return
	for failure in _failures:
		printerr("T17 UI SMOKE FAIL: %s" % failure)
	print("T17 UI SMOKE FAILED (%d)" % _failures.size())
	get_tree().quit(1)
