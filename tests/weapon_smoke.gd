extends Node
## T30 weapon smoke — пистолет: подбор, экипировка, хитскан, патроны, перезарядка,
## блокировка в диалоге. Запуск:
##   tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . tests/weapon_smoke.tscn
## Успех: строка "WEAPON SMOKE OK" в tools/weapon_smoke.log, exit 0.

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const PISTOL_SCENE := "res://scenes/objects/pistol.tscn"
const CONTROLLER_SCRIPT := "res://scripts/game/weapon_controller.gd"
const LOG_PATH := "res://tools/t51_weapon_smoke.log"
const MARKER_OK := "WEAPON SMOKE OK"

var _failures: Array[String] = []
var _checks: int = 0
var _log_lines: PackedStringArray = PackedStringArray()

var _player: Player = null
var _weapon: Weapon = null
var _controller: WeaponController = null
var _target: StaticBody3D = null

var _fired_count: int = 0
var _hit_count: int = 0
var _reloaded_count: int = 0
var _last_from: Vector3 = Vector3.ZERO
var _last_to: Vector3 = Vector3.ZERO
var _last_hit_target: Node = null
var _last_hit_damage: float = 0.0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_log("=== WEAPON SMOKE START ===")
	await get_tree().process_frame
	await _build_sandbox()
	_check_actions()
	_check_pistol_item()
	_check_pickup_and_equip()
	await _check_first_shot()
	await _check_cooldown_and_empty()
	await _check_reload()
	await _check_save_round_trip()
	_check_garbage_state()
	await _check_dialogue_block()
	_finish()


# --- Сцена -------------------------------------------------------------------


func _build_sandbox() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = 1
	floor_body.collision_mask = 1
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(40.0, 0.5, 40.0)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0.0, -0.25, 0.0)
	floor_body.add_child(floor_shape)
	add_child(floor_body)

	# Мишень впереди игрока: камера смотрит вдоль -Z.
	_target = StaticBody3D.new()
	_target.name = "SmokeTarget"
	_target.collision_layer = 1
	_target.collision_mask = 0
	_target.add_to_group("npc")
	_target.position = Vector3(0.0, 1.5, -6.0)
	var target_shape := CollisionShape3D.new()
	var target_box := BoxShape3D.new()
	target_box.size = Vector3(2.0, 2.0, 0.2)
	target_shape.shape = target_box
	_target.add_child(target_shape)
	add_child(_target)

	_player = (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
	_player.position = Vector3(0.0, 0.1, 0.0)
	add_child(_player)
	await _wait_physics_frames(4)

	_weapon = (load(PISTOL_SCENE) as PackedScene).instantiate() as Weapon
	_weapon.name = "SmokePistol"
	# На уровне камеры, чтобы существующий Interactor игрока видел Area3D подбора.
	_weapon.position = Vector3(0.0, 1.55, -1.5)
	add_child(_weapon)
	await _wait_physics_frames(3)
	var interactor := _player.get_interactor()
	_check(
		interactor != null and interactor.get_current_target() == _weapon,
		"Interactor не видит пистолет через PickupArea"
	)

	_controller = (load(CONTROLLER_SCRIPT) as GDScript).new() as WeaponController
	_controller.name = "SmokeWeaponController"
	_player.add_child(_controller)
	await get_tree().process_frame
	_check(_controller.get_parent() == _player, "WeaponController не под Player")
	_check(_controller.get_weapon() == _weapon, "WeaponController не нашёл пистолет в группе weapon")

	_weapon.fired.connect(_on_fired)
	_weapon.hit_target.connect(_on_hit_target)
	_weapon.reloaded.connect(_on_reloaded)


func _check_actions() -> void:
	_check(
		InputMap.has_action("weapon_toggle")
		and InputMap.has_action("fire")
		and InputMap.has_action("reload"),
		"в InputMap нет weapon_toggle/fire/reload"
	)
	var fire_has_lmb := false
	for event in InputMap.action_get_events("fire"):
		if event is InputEventMouseButton:
			if (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				fire_has_lmb = true
	_check(fire_has_lmb, "действие fire не привязано к ЛКМ")
	var toggle_has_f := false
	for event in InputMap.action_get_events("weapon_toggle"):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == KEY_F:
			toggle_has_f = true
	_check(toggle_has_f, "действие weapon_toggle не привязано к F")
	_log("[input] actions: weapon_toggle=%s fire=%s reload=%s" % [
		InputMap.has_action("weapon_toggle"),
		InputMap.has_action("fire"),
		InputMap.has_action("reload"),
	])


func _check_pistol_item() -> void:
	_check(_weapon.is_in_group("weapon"), "пистолет не в группе weapon")
	_check(_weapon.get_meta("interactable", false) == true, "нет meta interactable")
	_check(_weapon.has_method("interact"), "у пистолета нет метода interact")
	_check(_weapon.get_state() == Weapon.STATE_HOLSTERED, "стартовое состояние не holstered")


func _check_pickup_and_equip() -> void:
	_weapon.interact(_player) # E через Interactor: Area3D + interact()
	_check(_weapon.is_owned(), "пистолет не считается подобранным")
	_check(_weapon.get_owner_player() == _player, "owner_player не игрок")
	_check(not _weapon.pickup(_player), "повторный pickup не должен срабатывать")
	_check(_weapon.equip(), "equip() вернул false")
	_check(_weapon.get_state() == Weapon.STATE_EQUIPPED, "состояние не equipped")
	_check(_weapon.current_ammo == 8 and _weapon.reserve_ammo == 24,
		"стартовые патроны %d/%d вместо 8/24" % [
			_weapon.current_ammo, _weapon.reserve_ammo
		])
	_log("[pickup] state=%s ammo=%d/%d" % [
		_weapon.get_state(), _weapon.current_ammo, _weapon.reserve_ammo
	])


func _check_first_shot() -> void:
	var fired := _controller.try_fire()
	_check(fired, "controller.try_fire() вернул false в чистой сцене")
	_check(_weapon.current_ammo == 7, "патроны не убыли после выстрела (%d)" % _weapon.current_ammo)
	_check(_fired_count == 1, "сигнал fired не пришёл (%d)" % _fired_count)
	_check(_last_to.distance_to(_last_from) > 1.0, "fired: from и to совпадают")
	await _wait_physics_frames(2)
	_check(_hit_count == 1, "hit_target не пришёл после попадания в коллайдер (%d)" % _hit_count)
	_check(_last_hit_target == _target, "hit_target пришёл не от мишени")
	_check(is_equal_approx(_last_hit_damage, _weapon.damage), "hit_target: неверный урон")
	_log("[shot] ammo=%d fired=%d hit=%d target=%s" % [
		_weapon.current_ammo, _fired_count, _hit_count, str(_last_hit_target)
	])


func _check_cooldown_and_empty() -> void:
	_check(not _weapon.can_fire(), "can_fire() true сразу после выстрела (кулдаун)")
	await get_tree().create_timer(0.4).timeout
	_weapon.current_ammo = 0
	_check(not _weapon.can_fire(), "can_fire() true без патронов")
	_check(not _weapon.fire(), "fire() сработал без патронов")
	_check(_weapon.current_ammo == 0, "патроны изменились при пустом выстреле")
	_log("[empty] can_fire=false, fire=false, ammo=%d" % _weapon.current_ammo)


func _check_reload() -> void:
	_check(_weapon.reload(), "reload() не начался")
	_check(_weapon.is_reloading(), "состояние не reloading")
	await get_tree().create_timer(_weapon.reload_time + 0.2).timeout
	_check(not _weapon.is_reloading(), "перезарядка не завершилась")
	_check(_weapon.current_ammo == 8, "после перезарядки магазин %d вместо 8" % _weapon.current_ammo)
	_check(_weapon.reserve_ammo == 16, "после перезарядки запас %d вместо 16" % _weapon.reserve_ammo)
	_check(_reloaded_count == 1, "сигнал reloaded не пришёл (%d)" % _reloaded_count)
	_weapon.holster()
	_check(_weapon.get_state() == Weapon.STATE_HOLSTERED, "holster() не перевёл в holstered")
	_check(_weapon.equip(), "equip() после holster() не сработал")
	_log("[reload] ammo=%d/%d state=%s" % [
		_weapon.current_ammo, _weapon.reserve_ammo, _weapon.get_state()
	])


# --- Сейв: ammo/reserve переживают save/load и валидацию ---------------------


func _check_save_round_trip() -> void:
	_weapon.current_ammo = 3
	_weapon.reserve_ammo = 11
	var saved := SaveSystem.save_game(_player)
	_check(saved, "SaveSystem.save_game вернул false")
	var saved_quest: Dictionary = SaveSystem.get_saved_quest()
	var saved_pistol: Dictionary = {}
	var saved_states: Variant = saved_quest.get("item_states", {})
	if typeof(saved_states) == TYPE_DICTIONARY:
		var pistol_variant: Variant = (saved_states as Dictionary).get("pistol", {})
		if typeof(pistol_variant) == TYPE_DICTIONARY:
			saved_pistol = pistol_variant as Dictionary
	_check(
		int(saved_pistol.get("ammo", -1)) == 3 and int(saved_pistol.get("reserve", -1)) == 11,
		"в save.json item_states.pistol не 3/11: %s" % str(saved_pistol)
	)

	# Имитация перезапуска: живое оружие сброшено в дефолт, затем load.
	_weapon.current_ammo = 8
	_weapon.reserve_ammo = 24
	var loaded := SaveSystem.load_game(_player)
	_check(loaded, "SaveSystem.load_game вернул false")
	await get_tree().process_frame
	_check(_weapon.current_ammo == 3 and _weapon.reserve_ammo == 11,
		"после загрузки патроны %d/%d вместо 3/11" % [
			_weapon.current_ammo, _weapon.reserve_ammo
		])
	_log("[save] 3/11 -> save -> load -> %d/%d" % [
		_weapon.current_ammo, _weapon.reserve_ammo
	])


func _check_garbage_state() -> void:
	_weapon.apply_item_state({"ammo": 999, "reserve": -5})
	_check(_weapon.current_ammo == _weapon.magazine_size and _weapon.reserve_ammo == 0,
		"999/-5 не клампнулись в %d/0 (получили %d/%d)" % [
			_weapon.magazine_size, _weapon.current_ammo, _weapon.reserve_ammo
		])
	var ammo_before := _weapon.current_ammo
	var reserve_before := _weapon.reserve_ammo
	_weapon.apply_item_state({"ammo": "мусор", "reserve": {}})
	_check(_weapon.current_ammo == ammo_before and _weapon.reserve_ammo == reserve_before,
		"нечисловой мусор изменил патроны: %d/%d" % [
			_weapon.current_ammo, _weapon.reserve_ammo
		])
	_log("[state] мусор: ammo=999→%d, reserve=-5→%d, строки проигнорированы" % [
		ammo_before, reserve_before
	])


func _check_dialogue_block() -> void:
	var manager := get_node_or_null("/root/DialogueManager")
	_check(manager != null, "нет DialogueManager")
	if manager == null:
		return
	_check(manager.start("mila"), "диалог mila не стартовал для проверки блокировки")
	var dialogue_active := bool(manager.is_active())
	var ammo_before := _weapon.current_ammo
	var blocked := _controller.is_blocked()
	var fired := _controller.try_fire()
	_check(blocked, "is_blocked() false при открытом диалоге")
	_check(not fired, "try_fire() сработал при открытом диалоге")
	_check(_weapon.current_ammo == ammo_before, "патроны изменились при заблокированном выстреле")
	manager.close()
	await get_tree().process_frame
	_log("[block] dialogue_active=%s blocked=%s fired=%s" % [
		dialogue_active, blocked, fired
	])


# --- Сигналы -----------------------------------------------------------------


func _on_fired(from: Vector3, to: Vector3) -> void:
	_fired_count += 1
	_last_from = from
	_last_to = to


func _on_hit_target(target: Node, _position: Vector3, damage: float) -> void:
	_hit_count += 1
	_last_hit_target = target
	_last_hit_damage = damage


func _on_reloaded() -> void:
	_reloaded_count += 1


# --- Утилиты -----------------------------------------------------------------


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures.append(message)
	_log("[FAIL] %s" % message)


func _wait_physics_frames(count: int) -> void:
	for _frame in count:
		await get_tree().physics_frame


func _log(message: String) -> void:
	_log_lines.append(message)
	print(message)


func _finish() -> void:
	if _failures.is_empty():
		_log("%s (%d проверок)" % [MARKER_OK, _checks])
		_write_log()
		get_tree().quit(0)
		return
	_log("WEAPON SMOKE FAILED: %d из %d" % [_failures.size(), _checks])
	for failure in _failures:
		_log("  - %s" % failure)
	_write_log()
	push_error("WEAPON SMOKE FAILED: %d" % _failures.size())
	get_tree().quit(1)


func _write_log() -> void:
	var file := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[t30] не удалось записать %s (код %d)" % [
			LOG_PATH, FileAccess.get_open_error()
		])
		return
	file.store_string("\n".join(_log_lines) + "\n")
	file.close()
