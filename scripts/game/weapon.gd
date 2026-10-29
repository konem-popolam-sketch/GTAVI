class_name Weapon
extends Node3D
## Weapon — пистолет как игровой предмет: подбор, кобура, хитскан, патроны.
##
## Сцена: scenes/objects/pistol.tscn (модель из примитивов + Area3D подбора).
## Пока предмет лежит в мире, у корня включены meta "interactable" и метод
## interact(player) — его находит существующий Interactor игрока по E.
## После pickup() модель переходит к игроку: holstered (за кобурой, скрыта) /
## equipped (в руке) / reloading. Стрельба — хитскан из камеры игрока
## (PhysicsRayQueryParameters3D), не из ствола; ствол нужен только для вспышки
## и трассера.
##
## Числа (docs/weapon/README.md):
##   магазин 8, запас 24, перезарядка 1.6 с, интервал 0.35 с,
##   разброс 1.2° в движении / 0.3° стоя, урон 25, дальность 120 м.
##
## Публичный API:
##   pickup(player = null) -> bool
##   equip() -> bool; holster() -> bool
##   can_fire() -> bool; fire() -> bool
##   reload() -> bool
##   is_owned(); is_equipped(); is_reloading(); get_state() -> String
##   get_current_ammo() -> int; get_reserve_ammo() -> int
##   get_owner_player() -> Node3D; get_muzzle_position() -> Vector3
##   interact(player)  — вызывается Interactor'ом (E по предмету = подобрать)
## API:
##   ... + apply_item_state(state), get_item_state() -> Dictionary, get_item_id()
## Сохранение: SaveSystem кладёт ammo/reserve в quest.item_states["pistol"];
## при загрузке SaveSystem/спавн вызывают apply_item_state().
##
## Сигналы:
##   fired(from, to)
##   ammo_changed(current, reserve)
##   reloaded()
##   hit_target(target, position, damage)
##   picked_up(weapon, player)
##   state_changed(state)
##   equipped_changed(equipped)

signal fired(from: Vector3, to: Vector3)
signal ammo_changed(current: int, reserve: int)
signal reloaded()
signal hit_target(target: Node, position: Vector3, damage: float)
signal picked_up(weapon: Weapon, player: Node3D)
signal state_changed(state: String)
signal equipped_changed(equipped: bool)

const GROUP := "weapon"
const STATE_HOLSTERED := "holstered"
const STATE_EQUIPPED := "equipped"
const STATE_RELOADING := "reloading"

const PLAYER_GROUP := "player"
const PROJECTILE_SCENE := "res://scenes/objects/projectile.tscn"
const SFX_FIRE := "pistol_fire"
const SFX_RELOAD := "pistol_reload"
const SFX_EMPTY := "pistol_empty"

@export var magazine_size: int = 8
@export var start_reserve: int = 24
## Ключ в QuestState.item_states; под ним SaveSystem хранит ammo/reserve.
@export var item_id: String = "pistol"
@export var reload_time: float = 1.6
@export var fire_interval: float = 0.35
@export var spread_moving_degrees: float = 1.2
@export var spread_standing_degrees: float = 0.3
@export var damage: float = 25.0
@export var max_range: float = 120.0
@export var world_collision_mask: int = 1
## Смещение оружия в руке относительно игрока (x — вправо, z — вперёд).
@export var equipped_offset: Vector3 = Vector3(0.28, 1.16, -0.30)
@export var equipped_rotation_degrees: Vector3 = Vector3(-4.0, 3.0, 0.0)
## Сколько секунд живёт вспышка и трассер.
@export var muzzle_flash_time: float = 0.05
@export var tracer_time: float = 0.08

var state: String = STATE_HOLSTERED
var current_ammo: int = 8
var reserve_ammo: int = 24

var _owned: bool = false
var _owner_player: Node3D = null
var _next_fire_msec: int = 0
var _reload_token: int = 0
var _flash_token: int = 0
var _pickup_enabled: bool = true

var _model: Node3D = null
var _pickup_area: Area3D = null
var _muzzle: Node3D = null
var _flash_light: Light3D = null
var _flash_quad: MeshInstance3D = null


func _ready() -> void:
	add_to_group(GROUP)
	set_meta("interactable", true)
	set_meta("display_name", "Пистолет")
	_model = get_node_or_null("Model") as Node3D
	_pickup_area = get_node_or_null("PickupArea") as Area3D
	_muzzle = get_node_or_null("Muzzle") as Node3D
	_flash_light = get_node_or_null("Muzzle/FlashLight") as Light3D
	_flash_quad = get_node_or_null("Muzzle/FlashQuad") as MeshInstance3D
	current_ammo = clampi(current_ammo, 0, magazine_size)
	reserve_ammo = maxi(reserve_ammo, 0)
	_set_flash_visible(false)
	_set_model_visible(true)
	_set_pickup_enabled(true)
	set_process(true)
	# Сейв мог быть загружен до/после спавна узла — подхватим его на следующем кадре.
	call_deferred("_apply_state_from_quest")


func _process(_delta: float) -> void:
	if not _owned or _owner_player == null or not is_instance_valid(_owner_player):
		return
	if state == STATE_EQUIPPED or state == STATE_RELOADING:
		_update_equipment_transform()


# --- Публичный API ----------------------------------------------------------


## Подобрать пистолет с земли/прилавка. Возвращает false, если уже подобран.
func pickup(player: Node3D = null) -> bool:
	if _owned:
		return false
	var target := player
	if target == null:
		target = get_tree().get_first_node_in_group(PLAYER_GROUP) as Node3D
	if target == null:
		push_warning("[weapon] некуда подобрать: игрок не найден")
		return false
	_owner_player = target
	_owned = true
	top_level = true
	state = STATE_HOLSTERED
	_set_pickup_enabled(false)
	_set_model_visible(false)
	# Если предмет уже был в инвентаре/сейве — вернуть ammo/reserve до первого выстрела.
	_apply_state_from_quest()
	picked_up.emit(self, target)
	state_changed.emit(state)
	return true


## Достать оружие (F). Без подобранного пистолета — false.
func equip() -> bool:
	if not _owned:
		return false
	if state == STATE_EQUIPPED:
		return true
	if state == STATE_RELOADING:
		return false
	state = STATE_EQUIPPED
	_update_equipment_transform()
	_set_model_visible(true)
	state_changed.emit(state)
	equipped_changed.emit(true)
	return true


## Убрать оружие (F). Перезарядка отменяется.
func holster() -> bool:
	if not _owned or state == STATE_HOLSTERED:
		return false
	if state == STATE_RELOADING:
		_cancel_reload()
	state = STATE_HOLSTERED
	_set_model_visible(false)
	state_changed.emit(state)
	equipped_changed.emit(false)
	return true


## Можно ли стрелять прямо сейчас (без учёта диалога/паузы — это контроллер).
func can_fire() -> bool:
	if not _owned or state != STATE_EQUIPPED:
		return false
	if current_ammo <= 0:
		return false
	return Time.get_ticks_msec() >= _next_fire_msec


## Выстрел хитсканом из камеры игрока. Возвращает false, если нельзя.
func fire() -> bool:
	if not _owned or state != STATE_EQUIPPED:
		return false
	if current_ammo <= 0:
		_play_sfx(SFX_EMPTY)
		return false
	if Time.get_ticks_msec() < _next_fire_msec:
		return false
	var camera := _get_camera()
	if camera == null:
		return false

	var origin := camera.global_position
	var spread := deg_to_rad(_current_spread_degrees())
	var direction := _spread_direction(camera.global_transform.basis, spread)
	var ray_end := origin + direction * max_range
	var hit := _raycast(origin, ray_end)
	var impact := ray_end
	var target: Node = null
	if not hit.is_empty():
		var hit_position: Variant = hit.get("position", ray_end)
		if typeof(hit_position) == TYPE_VECTOR3:
			impact = hit_position
		target = _combat_target(hit.get("collider") as Node)

	current_ammo = maxi(current_ammo - 1, 0)
	_next_fire_msec = Time.get_ticks_msec() + int(round(fire_interval * 1000.0))
	ammo_changed.emit(current_ammo, reserve_ammo)
	fired.emit(origin, impact)
	_play_sfx(SFX_FIRE)
	_show_muzzle_flash()
	_spawn_tracer(_muzzle_global_position(), impact)
	if target != null:
		hit_target.emit(target, impact, damage)
		_flash_target(target)
	return true


## Начать перезарядку. Возвращает true, если перезарядка действительно началась.
func reload() -> bool:
	if not _owned or state != STATE_EQUIPPED:
		return false
	if current_ammo >= magazine_size or reserve_ammo <= 0:
		return false
	if state == STATE_RELOADING:
		return false
	state = STATE_RELOADING
	_reload_token += 1
	state_changed.emit(state)
	_play_sfx(SFX_RELOAD)
	_finish_reload_async(_reload_token)
	return true


func is_owned() -> bool:
	return _owned


func is_equipped() -> bool:
	return state == STATE_EQUIPPED or state == STATE_RELOADING


func is_reloading() -> bool:
	return state == STATE_RELOADING


func get_state() -> String:
	return state


func get_current_ammo() -> int:
	return current_ammo


func get_reserve_ammo() -> int:
	return reserve_ammo


## Ключ состояния в QuestState.item_states (SaveSystem пишет под ним ammo/reserve).
func get_item_id() -> String:
	return item_id


## Состояние для сохранения. Формат намеренно минимальный: {"ammo", "reserve"}.
func get_item_state() -> Dictionary:
	return {
		"ammo": current_ammo,
		"reserve": reserve_ammo,
	}


## Применить сохранённое состояние (после загрузки/спавна/подбора).
## Валидация: ammo клампится в 0…magazine_size, reserve в 0…999; нечисловой
## мусор игнорируется по полю и логируется "[weapon] item_state проигнорирован: …".
func apply_item_state(saved_state: Dictionary) -> void:
	if saved_state.is_empty():
		return
	var changed := false
	if saved_state.has("ammo"):
		var ammo_value: Variant = saved_state.get("ammo")
		if _is_number(ammo_value):
			current_ammo = clampi(int(ammo_value), 0, magazine_size)
			changed = true
		else:
			_log_ignored_state("ammo", ammo_value)
	if saved_state.has("reserve"):
		var reserve_value: Variant = saved_state.get("reserve")
		if _is_number(reserve_value):
			reserve_ammo = clampi(int(reserve_value), 0, 999)
			changed = true
		else:
			_log_ignored_state("reserve", reserve_value)
	if changed:
		ammo_changed.emit(current_ammo, reserve_ammo)


func get_owner_player() -> Node3D:
	return _owner_player


func get_muzzle_position() -> Vector3:
	return _muzzle_global_position()


## Единая точка входа Interactor'а: E по лежащему пистолету = подобрать.
func interact(player: Node3D = null) -> void:
	pickup(player)


# --- Внутреннее: состояние предмета ------------------------------------------


func _apply_state_from_quest() -> void:
	var quest := get_node_or_null("/root/QuestState")
	if quest == null or not quest.has_method("get_item_state"):
		return
	var saved: Variant = quest.call("get_item_state", item_id)
	if typeof(saved) != TYPE_DICTIONARY or (saved as Dictionary).is_empty():
		return
	apply_item_state(saved as Dictionary)


func _is_number(value: Variant) -> bool:
	var value_type := typeof(value)
	if value_type != TYPE_INT and value_type != TYPE_FLOAT:
		return false
	if value_type == TYPE_FLOAT and not is_finite(float(value)):
		return false
	return true


func _log_ignored_state(field: String, value: Variant) -> void:
	push_warning("[weapon] item_state проигнорирован: %s=%s" % [field, str(value)])


# --- Внутреннее: выстрел ----------------------------------------------------


func _get_camera() -> Camera3D:
	if _owner_player != null and is_instance_valid(_owner_player):
		if _owner_player.has_method("get_camera"):
			var camera: Variant = _owner_player.call("get_camera")
			if camera is Camera3D:
				return camera as Camera3D
	var viewport := get_viewport()
	return viewport.get_camera_3d() if viewport != null else null


func _current_spread_degrees() -> float:
	var body := _owner_player as CharacterBody3D
	if body == null:
		return spread_standing_degrees
	var planar_speed := Vector2(body.velocity.x, body.velocity.z).length()
	if planar_speed > 0.6 or not body.is_on_floor():
		return spread_moving_degrees
	return spread_standing_degrees


func _spread_direction(camera_basis: Basis, spread_radians: float) -> Vector3:
	var forward := -camera_basis.z.normalized()
	if spread_radians <= 0.0:
		return forward
	var yaw := randf_range(-spread_radians, spread_radians)
	var pitch := randf_range(-spread_radians, spread_radians)
	var right := camera_basis.x.normalized()
	var up := camera_basis.y.normalized()
	return forward.rotated(up, yaw).rotated(right, pitch).normalized()


func _raycast(origin: Vector3, end: Vector3) -> Dictionary:
	if not is_inside_tree():
		return {}
	var world := get_world_3d()
	if world == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(origin, end, world_collision_mask)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	# В Godot 4 query.exclude нужно присваивать массивом: append() к getter-копии
	# не меняет запрос, и луч попадает в собственное тело игрока.
	var exclude: Array[RID] = []
	if _owner_player is CollisionObject3D:
		exclude.append((_owner_player as CollisionObject3D).get_rid())
	query.exclude = exclude
	var result := world.direct_space_state.intersect_ray(query)
	return result if result != null else {}


## Ближайший узел-цель (NPC или объект с meta damageable). Мир — не цель.
func _combat_target(collider: Node) -> Node:
	var node := collider
	while node != null:
		if node.is_in_group("npc"):
			return node
		if node.has_meta("damageable") and bool(node.get_meta("damageable")):
			return node
		node = node.get_parent()
	return null


func _flash_target(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	var light := target.get_node_or_null("Highlight") as Light3D
	if light == null:
		return
	var base_energy := light.light_energy
	light.light_energy = base_energy * 2.4
	await get_tree().create_timer(0.12).timeout
	if is_instance_valid(light):
		light.light_energy = base_energy


# --- Внутреннее: перезарядка -------------------------------------------------


func _finish_reload_async(token: int) -> void:
	await get_tree().create_timer(reload_time).timeout
	if not is_inside_tree() or token != _reload_token or state != STATE_RELOADING:
		return
	var needed := magazine_size - current_ammo
	var taken := mini(needed, reserve_ammo)
	current_ammo += taken
	reserve_ammo -= taken
	state = STATE_EQUIPPED
	ammo_changed.emit(current_ammo, reserve_ammo)
	state_changed.emit(state)
	reloaded.emit()


func _cancel_reload() -> void:
	_reload_token += 1
	state = STATE_EQUIPPED


# --- Внутреннее: визуал ------------------------------------------------------


func _update_equipment_transform() -> void:
	if _owner_player == null or not is_instance_valid(_owner_player):
		return
	var target_position := (
		_owner_player.global_position
		+ _owner_player.global_transform.basis * equipped_offset
	)
	global_position = target_position
	global_rotation = Vector3(
		deg_to_rad(equipped_rotation_degrees.x),
		_owner_player.rotation.y + deg_to_rad(equipped_rotation_degrees.y),
		deg_to_rad(equipped_rotation_degrees.z)
	)


func _muzzle_global_position() -> Vector3:
	if _muzzle != null and is_instance_valid(_muzzle):
		return _muzzle.global_position
	if _owner_player != null and is_instance_valid(_owner_player):
		return global_position + (-global_transform.basis.z) * 0.25
	return global_position


func _show_muzzle_flash() -> void:
	if _flash_light == null and _flash_quad == null:
		return
	_flash_token += 1
	var token := _flash_token
	_set_flash_visible(true)
	await get_tree().create_timer(muzzle_flash_time).timeout
	if token == _flash_token:
		_set_flash_visible(false)


func _set_flash_visible(value: bool) -> void:
	if _flash_light != null and is_instance_valid(_flash_light):
		_flash_light.visible = value
	if _flash_quad != null and is_instance_valid(_flash_quad):
		_flash_quad.visible = value


func _spawn_tracer(from: Vector3, to: Vector3) -> void:
	if from.distance_to(to) < 0.05:
		return
	var scene := load(PROJECTILE_SCENE) as PackedScene
	if scene == null:
		return
	var tracer := scene.instantiate()
	var host := get_tree().current_scene
	if host == null:
		host = get_tree().root
	if host == null:
		tracer.queue_free()
		return
	host.add_child(tracer)
	if tracer.has_method("launch"):
		tracer.call("launch", from, to, tracer_time)


func _set_model_visible(value: bool) -> void:
	if _model != null and is_instance_valid(_model):
		_model.visible = value
	if not value:
		_set_flash_visible(false)


func _set_pickup_enabled(value: bool) -> void:
	_pickup_enabled = value
	set_meta("interactable", value)
	if _pickup_area != null and is_instance_valid(_pickup_area):
		_pickup_area.collision_layer = 1 if value else 0
		_pickup_area.monitorable = value


# --- Внутреннее: звук --------------------------------------------------------


## Имена ждём от звукового отдела: pistol_fire, pistol_reload, pistol_empty.
## Пока файлов нет — тихо пропускаем (без warning'ов и падений).
func _play_sfx(name: String) -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio == null or not audio.has_method("play_sfx"):
		return
	if audio.has_method("get_stream"):
		var stream: Variant = audio.call("get_stream", name, "sfx", false)
		if stream == null:
			return
	audio.call("play_sfx", name, global_position)
