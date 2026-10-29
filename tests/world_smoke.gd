extends SceneTree
## T18 WORLD SMOKE — расширенный район «Ночной смены».
##
## Проверяет сцену scenes/world/block.tscn без окна и без игрока:
##   1) PlayerSpawn существует, стоит на полу, капсула игрока (r=0.4) не застревает;
##   2) все старые POI/NPC-слоты сохранены, новые добавлены, get_poi()/get_poi_names()
##      и get_npc_slot()/get_npc_slot_names() работают;
##   3) каждый POI стоит на полу и не вмурован в стену;
##   4) до каждого POI есть пешеходный маршрут из world.gd, и луч на высоте пояса
##      не встречает стен ни на одном сегменте (крыша, двор, переулки, причал);
##   5) в новой части района нет пустых коллизий и нет CSG-коллизий: только
##      StaticBody3D с BoxShape3D.
##
## Запуск:
##   tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . \
##       --script res://tests/world_smoke.gd --log-file tools\t18_world_smoke.log
## Успех — строка "T18 WORLD SMOKE OK" и код возврата 0.

const BLOCK_SCENE := "res://scenes/world/block.tscn"
const SPAWN := Vector3(0.0, 0.1, 10.0)
const COLLISION_MASK := 1

const OLD_POIS := [
	&"POI_Shop", &"POI_Pier", &"POI_Fence", &"POI_Alley",
]
const NEW_POIS := [
	&"POI_ShopPorch", &"POI_Courtyard", &"POI_BackPassage",
	&"POI_Alley2", &"POI_Rooftop", &"POI_WaterStairs", &"POI_Quay",
]
const OLD_NPC_SLOTS := [
	&"NPC_Mila", &"NPC_Foreman", &"NPC_Kostya", &"NPC_Phone",
]
const NEW_NPC_SLOTS := [
	&"NPC_Alley2", &"NPC_Courtyard", &"NPC_Rooftop", &"NPC_Quay",
]
## Позиции старых POI — контракт с main.tscn и save: не должны съехать.
var OLD_POI_POSITIONS: Dictionary = {
	&"POI_Shop": Vector3(-4, 0, -10.9),
	&"POI_Pier": Vector3(0, -0.7, 34.5),
	&"POI_Fence": Vector3(-8.2, 0, 11.5),
	&"POI_Alley": Vector3(4, 0, -11.6),
}

const MIN_STATIC_BODIES := 30
const CLEARANCE_RADIUS := 0.1
const BELT_HEIGHT := 0.9

var _failures: Array[String] = []
var _world: Node3D = null
var _space: PhysicsDirectSpaceState3D = null
var _route_segments := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed := load(BLOCK_SCENE) as PackedScene
	if packed == null:
		_fail("не удалось загрузить %s" % BLOCK_SCENE)
		_finish()
		return
	_world = packed.instantiate() as Node3D
	if _world == null:
		_fail("block.tscn не инстанцируется как Node3D")
		_finish()
		return
	root.add_child(_world)
	# CSG-геометрия и StaticBody3D должны попасть в физический мир до raycast'ов.
	for _i in 5:
		await physics_frame
	await process_frame
	_space = _world.get_world_3d().direct_space_state
	if _space == null:
		_fail("нет PhysicsDirectSpaceState3D у сцены мира")
		_finish()
		return

	_check_spawn()
	_check_poi_registry()
	_check_npc_registry()
	_check_poi_ground_and_space()
	_check_walk_routes()
	_check_collision_hygiene()
	_finish()


# --- 1. Спавн игрока ---------------------------------------------------------


func _check_spawn() -> void:
	var marker := _world.get_node_or_null("Markers/PlayerSpawn") as Marker3D
	_expect(marker != null, "в сцене нет Markers/PlayerSpawn")
	if marker == null:
		return
	var spawn := marker.global_position
	_expect(spawn.distance_to(SPAWN) < 0.05, "PlayerSpawn сместился: %s" % spawn)
	var spawn_tf: Transform3D = _world.get_spawn_transform()
	_expect(spawn_tf.origin.distance_to(spawn) < 0.01, "get_spawn_transform() не совпадает с маркером")
	var floor_hit := _ray(spawn + Vector3(0, 2, 0), spawn - Vector3(0, 0.6, 0))
	_expect(not floor_hit.is_empty(), "под PlayerSpawn нет пола")
	if not floor_hit.is_empty():
		var floor_y: float = (floor_hit["position"] as Vector3).y
		_expect(absf(floor_y - 0.0) < 0.15, "пол под спавном на высоте %.2f" % floor_y)
	_expect(
		_sphere_free(spawn + Vector3(0, 0.9, 0), 0.4),
		"капсула игрока на спавне застревает"
	)


# --- 2. Реестр POI и NPC-слотов ---------------------------------------------


func _check_poi_registry() -> void:
	_expect(_world.has_method("get_poi_names"), "у world.gd нет get_poi_names()")
	var names: PackedStringArray = _world.get_poi_names()
	_expect(
		names.size() >= OLD_POIS.size() + NEW_POIS.size(),
		"POI меньше ожидаемого: %d" % names.size()
	)
	_expect_unique(names, "POI")
	for poi in OLD_POIS:
		_expect(names.has(String(poi)), "пропал старый %s" % poi)
	for poi in NEW_POIS:
		_expect(names.has(String(poi)), "не добавлен новый %s" % poi)
	for poi in names:
		var marker := _world.get_node_or_null("PointsOfInterest/%s" % poi) as Marker3D
		_expect(marker != null, "POI %s не Marker3D под PointsOfInterest" % poi)
		if marker == null:
			continue
		var via_api: Vector3 = _world.get_poi(StringName(poi))
		_expect(
			via_api.distance_to(marker.global_position) < 0.01,
			"get_poi(%s) не совпадает с узлом" % poi
		)
		var area: StringName = _world.get_poi_area(StringName(poi))
		_expect(area != &"unknown", "у POI %s не описан район" % poi)
	for poi in OLD_POIS:
		var expected: Vector3 = OLD_POI_POSITIONS[poi]
		var actual: Vector3 = _world.get_poi(poi)
		_expect(
			actual.distance_to(expected) < 0.01,
			"старый %s съехал: %s вместо %s" % [poi, actual, expected]
		)


func _check_npc_registry() -> void:
	_expect(_world.has_method("get_npc_slot_names"), "у world.gd нет get_npc_slot_names()")
	var slots: PackedStringArray = _world.get_npc_slot_names()
	_expect(
		slots.size() >= OLD_NPC_SLOTS.size() + NEW_NPC_SLOTS.size(),
		"NPC-слотов меньше ожидаемого: %d" % slots.size()
	)
	_expect_unique(slots, "NPC slot")
	for slot in OLD_NPC_SLOTS:
		_expect(slots.has(String(slot)), "пропал старый слот %s" % slot)
	for slot in NEW_NPC_SLOTS:
		_expect(slots.has(String(slot)), "не добавлен слот %s" % slot)
	for slot in slots:
		var marker := _world.get_node_or_null("Markers/NpcSlots/%s" % slot) as Marker3D
		_expect(marker != null, "слот %s не Marker3D под Markers/NpcSlots" % slot)
		if marker == null:
			continue
		var via_api: Vector3 = _world.get_npc_slot(StringName(slot))
		_expect(via_api.distance_to(marker.global_position) < 0.01, "get_npc_slot(%s) врёт" % slot)


# --- 3. POI стоят на полу и не вмурованы ------------------------------------


func _check_poi_ground_and_space() -> void:
	var poi_names: PackedStringArray = _world.get_poi_names()
	for poi in poi_names:
		var pos: Vector3 = _world.get_poi(StringName(poi))
		var down := _ray(pos + Vector3(0, 2.5, 0), pos - Vector3(0, 0.35, 0))
		_expect(not down.is_empty(), "POI %s висит над пустотой" % poi)
		if not down.is_empty():
			var hit_y: float = (down["position"] as Vector3).y
			_expect(hit_y <= pos.y + 0.25, "POI %s: пол выше маркера (%.2f)" % [poi, hit_y])
			_expect(hit_y >= pos.y - 0.35, "POI %s: пол ниже маркера на %.2f м" % [poi, pos.y - hit_y])
		_expect(
			_sphere_free(pos + Vector3(0, 1.0, 0), CLEARANCE_RADIUS),
			"POI %s вмурован в стену/перекрыт" % poi
		)


# --- 4. Маршруты от спавна до POI -------------------------------------------


func _check_walk_routes() -> void:
	_expect(_world.has_method("get_walk_route"), "у world.gd нет get_walk_route()")
	if not _world.has_method("get_walk_route"):
		return
	var poi_names: PackedStringArray = _world.get_poi_names()
	for poi in poi_names:
		var route: PackedVector3Array = _world.get_walk_route(StringName(poi))
		_expect(route.size() >= 2, "для %s нет маршрута" % poi)
		if route.size() < 2:
			continue
		_expect(route[0].distance_to(SPAWN) < 0.05, "маршрут %s начинается не на спавне" % poi)
		var target: Vector3 = _world.get_poi(StringName(poi))
		_expect(
			route[route.size() - 1].distance_to(target) < 0.05,
			"маршрут %s не доходит до POI" % poi
		)
		for i in range(1, route.size()):
			var from: Vector3 = route[i - 1] + Vector3(0, BELT_HEIGHT, 0)
			var to: Vector3 = route[i] + Vector3(0, BELT_HEIGHT, 0)
			if from.distance_to(to) < 0.01:
				continue
			var hit := _ray(from, to)
			_route_segments += 1
			if not hit.is_empty():
				var collider: Node = hit.get("collider") as Node
				var hit_pos: Vector3 = hit.get("position") as Vector3
				var collider_name := "?"
				if collider != null:
					collider_name = String(collider.name)
				_expect(
					false,
					"маршрут %s перекрыт на сегменте %d (%s, %s)" % [
						poi, i, collider_name, hit_pos
					]
				)


# --- 5. Гигиена коллизий ----------------------------------------------------


func _check_collision_hygiene() -> void:
	var empty_shapes := 0
	var static_bodies := 0
	var box_shapes := 0
	for node in _all_nodes(_world):
		if node is CollisionShape3D:
			var shape_node := node as CollisionShape3D
			if shape_node.shape == null:
				empty_shapes += 1
			elif shape_node.shape is BoxShape3D:
				var box := shape_node.shape as BoxShape3D
				box_shapes += 1
				if box.size.x <= 0.0 or box.size.y <= 0.0 or box.size.z <= 0.0:
					_expect(false, "пустая BoxShape3D у %s" % shape_node.get_path())
		elif node is StaticBody3D:
			static_bodies += 1
			var has_shape := false
			for child in node.get_children():
				if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
					has_shape = true
			_expect(has_shape, "StaticBody3D %s без коллизии" % node.name)
	_expect(empty_shapes == 0, "пустых CollisionShape3D: %d" % empty_shapes)
	_expect(static_bodies >= MIN_STATIC_BODIES, "StaticBody3D слишком мало: %d" % static_bodies)
	_expect(box_shapes >= MIN_STATIC_BODIES, "BoxShape3D слишком мало: %d" % box_shapes)

	# В новой части района запрещены CSG-коллизии (игрок за них цепляется):
	# только StaticBody3D + BoxShape3D.
	var district := _world.get_node_or_null("DistrictExpansion")
	_expect(district != null, "нет узла DistrictExpansion")
	if district != null:
		var csg_collisions := 0
		for node in _all_nodes(district):
			if node is CSGBox3D and (node as CSGBox3D).use_collision:
				csg_collisions += 1
			if node is CollisionShape3D:
				_expect(
					(node.get_parent() as Node) is StaticBody3D,
					"коллизия %s не под StaticBody3D" % node.name
				)
		_expect(csg_collisions == 0, "CSG-коллизий в новом районе: %d" % csg_collisions)
	print("[world-smoke] StaticBody3D=%d, BoxShape3D=%d, POI=%d, NPC slots=%d, сегментов маршрутов=%d" % [
		static_bodies, box_shapes, _world.get_poi_names().size(),
		_world.get_npc_slot_names().size(), _route_segments
	])


# --- Инфраструктура ---------------------------------------------------------


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, COLLISION_MASK)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return _space.intersect_ray(query)


func _sphere_free(center: Vector3, radius: float) -> bool:
	var shape := SphereShape3D.new()
	shape.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), center)
	query.collision_mask = COLLISION_MASK
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return _space.intersect_shape(query, 1).is_empty()


func _all_nodes(root_node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child in root_node.get_children():
		result.append(child)
		result.append_array(_all_nodes(child))
	return result


func _expect_unique(names: PackedStringArray, what: String) -> void:
	var seen := {}
	for item in names:
		if seen.has(item):
			_expect(false, "%s дублируется: %s" % [what, item])
		seen[item] = true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _fail(message: String) -> void:
	_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		if _world == null:
			_failures.append("мир не загружен")
		else:
			print("T18 WORLD SMOKE OK: спавн, %d POI, %d NPC-слотов, маршруты без стен, коллизии чистые" % [
				_world.get_poi_names().size(), _world.get_npc_slot_names().size()
			])
			quit(0)
			return
	for failure in _failures:
		push_error("[world-smoke] " + failure)
	print("T18 WORLD SMOKE FAILED (%d): %s" % [
		_failures.size(), "; ".join(PackedStringArray(_failures))
	])
	quit(1)
