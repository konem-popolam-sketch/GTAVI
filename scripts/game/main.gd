extends Node3D
## Корневая игровая сцена «Ночной смены» — интеграция мира, игрока, NPC и UI.
##
## Задачи этого скрипта:
##   1) при старте поднять сохранение (user://save.json) и поставить игрока
##      туда, где он остановился; если сохранения нет — на PlayerSpawn из мира;
##   2) при выходе/закрытии окна сохранить позицию (SaveSystem.save_game);
##   3) отдать наружу удобный доступ к узлам сцены и напечатать сводку для
##      headless-проверки.
##
## Аргументы командной строки (запуск: godot --headless --path . -- <arg>):
##   --dump-scene   напечатать сводку сцены: POI, NPC, игрок, сохранение
##   --fresh        игнорировать сохранение и начать с точки спавна
##
## Публичный API:
##   get_player() -> Player; get_world() -> Node3D
##   start_fresh() — сброс прогресса и возврат на спавн
##   save_progress(); dump_scene_summary()

signal session_ready(saved_loaded: bool)

@export var load_save_on_start: bool = true
@export var save_on_exit: bool = true
@export var print_startup_summary: bool = true

var _world: Node3D = null
var _player: Player = null
var _saved_loaded: bool = false
var _progress_saved: bool = false


func _ready() -> void:
	_world = get_node_or_null("World") as Node3D
	_player = get_node_or_null("Player") as Player
	# Сохраняемся, пока узел ещё в дереве: SceneTree гасит сцену через quit(),
	# и в _exit_tree узлы уже не в дереве (global_position там уже не прочитать).
	tree_exiting.connect(save_progress)
	call_deferred("_start_session")


func _notification(what: int) -> void:
	# Закрытие окна: сначала сохраняемся, потом выходим.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		save_progress()
		if is_inside_tree():
			get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	# Пауза (Esc) — удобная точка сохранить прогресс, игра при этом не останавливается:
	# паузу обрабатывает игрок/UI, мы только фиксируем позицию на диск.
	if event.is_action_pressed("pause"):
		save_progress()


# --- Публичный API -----------------------------------------------------------


func get_player() -> Player:
	return _player


func get_world() -> Node3D:
	return _world


## Начать с чистого листа: сбросить квест, удалить сохранение, вернуть игрока на спавн.
func start_fresh() -> void:
	var quest := get_node_or_null("/root/QuestState")
	if quest != null and quest.has_method("reset"):
		quest.reset()
	SaveSystem.delete_save()
	_progress_saved = false
	_place_player_at_spawn()
	if _player != null:
		print("[main] новый проход: игрок на спавне %s" % _player.global_position)


func save_progress() -> void:
	if not save_on_exit or _progress_saved:
		return
	if _player == null or not is_instance_valid(_player):
		return
	# Вне дерева у Node3D нельзя спросить global_position — молча пропускаем.
	if not is_inside_tree() or not _player.is_inside_tree():
		return
	_progress_saved = true
	SaveSystem.save_game(_player)


## Сводка сцены в лог: проверка сборки без окна и справка для отладки.
func dump_scene_summary() -> void:
	print("[main] NIGHT SHIFT — session summary")
	print("[main] scene=%s, player=%s" % [
		name, "ok" if _player != null else "MISSING"
	])
	if _player != null:
		print("[main] player position = %s" % _player.global_position)
	if _world != null:
		var marked_world := _world as Node3D
		if marked_world.has_method("dump_world_summary"):
			marked_world.dump_world_summary()
	for npc in get_tree().get_nodes_in_group("npc"):
		var npc_id: String = ""
		if npc.has_method("get_dialogue_id"):
			npc_id = str(npc.get_dialogue_id())
		print("[main] npc %s dialogue='%s' at %s" % [
			npc.name, npc_id, (npc as Node3D).global_position
		])
	print("[main] save exists = %s, path = %s (%s)" % [
		SaveSystem.has_save(), SaveSystem.get_save_path(),
		ProjectSettings.globalize_path("user://")
	])


# --- Внутреннее --------------------------------------------------------------


func _start_session() -> void:
	if _player == null:
		push_warning("[main] в корневой сцене нет узла Player — игрок не появится")
	if _has_arg("--fresh"):
		start_fresh()
		_saved_loaded = false
	elif load_save_on_start and SaveSystem.has_save():
		_saved_loaded = SaveSystem.load_game(_player)
		if _saved_loaded:
			print("[main] сохранение загружено: игрок в %s" % _player.global_position)
	if not _saved_loaded:
		_place_player_at_spawn()
	if print_startup_summary or _has_arg("--dump-scene"):
		dump_scene_summary()
	# Служебный хук для проверки сохранения без окна: сохранить и сразу выйти.
	if _has_arg("--save-now"):
		save_progress()
		print("[main] сохранение записано: игрок в %s" % _player.global_position)
		get_tree().quit()
		return
	session_ready.emit(_saved_loaded)


func _place_player_at_spawn() -> void:
	if _player == null:
		return
	var spawn := Transform3D.IDENTITY
	if _world != null and _world.has_method("get_spawn_transform"):
		spawn = _world.get_spawn_transform()
	_player.teleport_to(spawn.origin)
	_player.rotation.y = spawn.basis.get_euler().y


func _has_arg(arg: String) -> bool:
	return OS.get_cmdline_args().has(arg) or OS.get_cmdline_user_args().has(arg)
