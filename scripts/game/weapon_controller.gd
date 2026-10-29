class_name WeaponController
extends Node
## WeaponController — отдельный узел управления оружием (не правит player.gd).
##
## Интеграция (t20): добавить этот узел ребёнком Player (или любым узлом сцены):
##   Player/WeaponController (Node, script scripts/game/weapon_controller.gd)
## Контроллер сам находит Player по группе "player", а пистолет — по группе
## "weapon", и слушает ввод:
##   F (weapon_toggle) — достать/убрать
##   ЛКМ (fire)        — выстрел
##   R (reload)        — перезарядка
##
## Стрельба/перезарядка/доставание блокируются, пока:
##   - открыт диалог (DialogueManager.is_active()),
##   - открыта пауза (get_tree().paused или PauseMenu.is_open()),
##   - висит титульная плашка (группа title_card, is_open()),
##   - у игрока выключено управление (концовка/катсцена).
##
## Публичный API:
##   try_toggle() -> bool; try_fire() -> bool; try_reload() -> bool
##   is_blocked() -> bool
##   has_weapon() -> bool; get_weapon() -> Weapon
##   is_weapon_equipped() -> bool
## Сигналов своих нет: подписывайся на сигналы Weapon (ammo_changed,
## state_changed, fired, hit_target) — их можно пробросить в HUD.

const PLAYER_GROUP := "player"
const WEAPON_GROUP := "weapon"

@export var weapon_path: NodePath
@export var auto_find_weapon: bool = true

var _player: Node3D = null
var _weapon: Weapon = null


func _ready() -> void:
	_player = _find_player()
	if not weapon_path.is_empty():
		var node := get_node_or_null(weapon_path)
		if node is Weapon:
			_weapon = node as Weapon
	call_deferred("_ensure_weapon")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.echo:
			return
	if event.is_action_pressed("weapon_toggle"):
		if not is_blocked():
			try_toggle()
	elif event.is_action_pressed("fire"):
		if not is_blocked():
			try_fire()
	elif event.is_action_pressed("reload"):
		if not is_blocked():
			try_reload()


# --- Публичный API ----------------------------------------------------------


## Достать/убрать оружие. Без подобранного пистолета — false.
func try_toggle() -> bool:
	_ensure_weapon()
	if _weapon == null or not _weapon.is_owned():
		return false
	if _weapon.is_equipped():
		return _weapon.holster()
	return _weapon.equip()


## Выстрел с учётом блокировок (диалог/пауза/плашка/концовка).
func try_fire() -> bool:
	if is_blocked():
		return false
	_ensure_weapon()
	if _weapon == null:
		return false
	return _weapon.fire()


func try_reload() -> bool:
	if is_blocked():
		return false
	_ensure_weapon()
	if _weapon == null:
		return false
	return _weapon.reload()


## Заблокирован ли ввод оружия прямо сейчас.
func is_blocked() -> bool:
	if get_tree().paused:
		return true
	var manager := get_node_or_null("/root/DialogueManager")
	if manager != null and manager.has_method("is_active"):
		if bool(manager.call("is_active")):
			return true
	if _title_card_open():
		return true
	if _pause_menu_open():
		return true
	if _player == null or not is_instance_valid(_player):
		_player = _find_player()
	if _player != null:
		var controls: Variant = _player.get("controls_enabled")
		if typeof(controls) == TYPE_BOOL and not bool(controls):
			return true
	return false


func has_weapon() -> bool:
	_ensure_weapon()
	return _weapon != null and _weapon.is_owned()


func get_weapon() -> Weapon:
	_ensure_weapon()
	return _weapon


func is_weapon_equipped() -> bool:
	return _weapon != null and _weapon.is_equipped()


# --- Внутреннее --------------------------------------------------------------


func _find_player() -> Node3D:
	if get_parent() != null and get_parent().is_in_group(PLAYER_GROUP):
		return get_parent() as Node3D
	return get_tree().get_first_node_in_group(PLAYER_GROUP) as Node3D


func _ensure_weapon() -> void:
	if _weapon != null and is_instance_valid(_weapon):
		return
	if not weapon_path.is_empty():
		var node := get_node_or_null(weapon_path)
		if node is Weapon:
			_weapon = node as Weapon
			return
	if not auto_find_weapon or not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group(WEAPON_GROUP):
		if node is Weapon:
			_weapon = node as Weapon
			return


func _title_card_open() -> bool:
	for node in get_tree().get_nodes_in_group("title_card"):
		if node.has_method("is_open") and bool(node.call("is_open")):
			return true
	return false


func _pause_menu_open() -> bool:
	var menu := get_tree().get_first_node_in_group("pause_menu")
	if menu != null and menu.has_method("is_open"):
		return bool(menu.call("is_open"))
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var named := scene.find_child("PauseMenu", true, false)
	if named != null and named.has_method("is_open"):
		return bool(named.call("is_open"))
	return false
