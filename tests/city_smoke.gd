extends Node
## T32 CITY SMOKE — город вокруг исторического центра.
##
## Проверяет:
##   1) размер города ≥ 350×350 м по get_city_bounds();
##   2) в реестре POI есть клуб, гараж, заправка, мостик и всего ≥ 8 точек;
##   3) спавн стоит на полу;
##   4) кольцевой маршрут get_road_path() замкнут, ≥ 20 точек, каждая точка
##      внутри границ, все сегменты свободны (машина проедет);
##   5) по всей площади города нет дыр: луч сверху всегда попадает в пол/крышу;
##   6) у коллизий города нет пустых шейпов, здания — StaticBody3D, а не CSG;
##   7) число источников света укладывается в бюджет (после T48 — 58 из 60).
##
## Запуск:
##   tools\Godot_v4.7.2-stable_win64_console.exe --headless --path . \
##       res://tests/city_smoke.tscn --log-file tools/city_smoke.log
## Успех — строка "CITY SMOKE OK" и код возврата 0.

const BLOCK_SCENE := "res://scenes/world/block.tscn"
const SPAWN := Vector3(0.0, 0.1, 10.0)
const MIN_CITY_SIZE := 350.0
const MIN_POI_COUNT := 8
const MIN_ROAD_POINTS := 20
const MAX_OMNI_LIGHTS := 60
## T48: 54 (T44) + 2 света перекрёстка + 2 тёплых света витрин клуба.
const EXPECTED_OMNI_LIGHTS := 58
const MAX_CITY_NODES := 5000
const COLLISION_MASK := 1
const BELT_HEIGHT := 0.5

const REQUIRED_POIS := [
	&"POI_Shop", &"POI_Pier", &"POI_Club", &"POI_Garage", &"POI_Fuel",
	&"POI_Bridge", &"POI_Parking",
]

var failures: Array[String] = []
var world: Node3D = null
var space: PhysicsDirectSpaceState3D = null
var road_segments := 0


func _ready() -> void:
	print("=== T32 CITY SMOKE START ===")
	await get_tree().process_frame
	var packed := load(BLOCK_SCENE) as PackedScene
	if packed == null:
		_expect(false, "не загрузилась scenes/world/block.tscn")
		_finish()
		return
	world = packed.instantiate() as Node3D
	if world == null:
		_expect(false, "block.tscn не инстанцируется как Node3D")
		_finish()
		return
	add_child(world)
	for _frame in 5:
		await get_tree().physics_frame
	await get_tree().process_frame
	space = world.get_world_3d().direct_space_state
	if space == null:
		_expect(false, "нет PhysicsDirectSpaceState3D")
		_finish()
		return

	_check_city_bounds()
	_check_pois()
	_check_spawn()
	_check_road_path()
	_check_ground_coverage()
	_check_city_collisions()
	_check_light_budget()
	_finish()


func _check_city_bounds() -> void:
	var bounds: AABB = world.get_city_bounds()
	_expect(
		bounds.size.x >= MIN_CITY_SIZE,
		"город уже %.0f м по X (нужно ≥ %.0f)" % [bounds.size.x, MIN_CITY_SIZE]
	)
	_expect(
		bounds.size.z >= MIN_CITY_SIZE,
		"город уже %.0f м по Z (нужно ≥ %.0f)" % [bounds.size.z, MIN_CITY_SIZE]
	)
	_expect(bounds.size.y > 0.0, "у границ города нулевая высота")
	_expect(
		bounds.has_point(Vector3(0.0, 0.0, -200.0)),
		"центр городской сетки вне get_city_bounds()"
	)
	print("[city-smoke] bounds: %s, size %.0f×%.0f×%.0f м" % [
		bounds.position, bounds.size.x, bounds.size.y, bounds.size.z
	])


func _check_pois() -> void:
	var names: PackedStringArray = world.get_poi_names()
	_expect(names.size() >= MIN_POI_COUNT, "POI всего %d (нужно ≥ %d)" % [names.size(), MIN_POI_COUNT])
	for poi in REQUIRED_POIS:
		_expect(names.has(String(poi)), "нет обязательного POI %s" % poi)
		var position: Vector3 = world.get_poi(poi)
		_expect(position != Vector3.ZERO, "get_poi(%s) вернул ZERO" % poi)
	print("[city-smoke] POI: %d — %s" % [names.size(), ", ".join(names)])


func _check_spawn() -> void:
	var spawn_transform: Transform3D = world.get_spawn_transform()
	var origin := spawn_transform.origin
	_expect(origin.distance_to(SPAWN) < 0.5, "спавн сместился: %s" % origin)
	var hit := _ray(origin + Vector3(0, 2.0, 0), origin - Vector3(0, 1.0, 0))
	_expect(not hit.is_empty(), "под спавном нет пола")
	if not hit.is_empty():
		var floor_y: float = (hit["position"] as Vector3).y
		_expect(absf(floor_y - 0.0) < 0.25, "пол под спавном на высоте %.2f" % floor_y)
		print("[city-smoke] spawn: %s, floor_y=%.2f" % [origin, floor_y])


func _check_road_path() -> void:
	var path: PackedVector3Array = world.get_road_path()
	_expect(path.size() >= MIN_ROAD_POINTS, "в кольцевом маршруте %d точек (нужно ≥ %d)" % [
		path.size(), MIN_ROAD_POINTS
	])
	if path.size() < 2:
		return
	var closure: float = path[0].distance_to(path[path.size() - 1])
	_expect(closure < 1.0, "маршрут не замкнут: разрыв %.2f м" % closure)
	var bounds: AABB = world.get_city_bounds()
	var grown_bounds := bounds.grow(2.0)
	for point in path:
		_expect(grown_bounds.has_point(point), "точка маршрута %s вне города" % point)
	for i in range(1, path.size()):
		var from: Vector3 = path[i - 1] + Vector3(0, BELT_HEIGHT, 0)
		var to: Vector3 = path[i] + Vector3(0, BELT_HEIGHT, 0)
		if from.distance_to(to) < 0.01:
			continue
		road_segments += 1
		var hit := _ray(from, to)
		if not hit.is_empty():
			var collider: Node = hit.get("collider") as Node
			var collider_name := "?"
			if collider != null:
				collider_name = String(collider.name)
			_expect(false, "кольцо перекрыто на сегменте %d (%s)" % [i, collider_name])
	print("[city-smoke] road loop: %d точек, замыкание %.2f м, сегментов %d" % [
		path.size(), closure, road_segments
	])


func _check_ground_coverage() -> void:
	var misses := 0
	var samples := 0
	var x := -178.0
	while x <= 178.0:
		var z := -388.0
		while z <= -34.0:
			samples += 1
			var hit := _ray(Vector3(x, 60.0, z), Vector3(x, -1.0, z))
			if hit.is_empty():
				misses += 1
				if misses <= 5:
					_expect(false, "дыра в геометрии на (%.0f, %.0f)" % [x, z])
			else:
				var floor_y: float = (hit["position"] as Vector3).y
				if floor_y < -0.5:
					misses += 1
					if misses <= 5:
						_expect(false, "пол ниже −0.5 м на (%.0f, %.0f)" % [x, z])
			z += 20.0
		x += 20.0
	print("[city-smoke] ground coverage: %d проб, дыр %d" % [samples, misses])


func _check_city_collisions() -> void:
	var city := world.get_node_or_null("City")
	_expect(city != null, "нет узла City")
	if city == null:
		return
	var static_bodies := 0
	var empty_shapes := 0
	var csg_collisions := 0
	for node in _all_nodes(city):
		if node is CollisionShape3D:
			var shape_node := node as CollisionShape3D
			if shape_node.shape == null:
				empty_shapes += 1
			elif shape_node.shape is BoxShape3D:
				var box := shape_node.shape as BoxShape3D
				if box.size.x <= 0.0 or box.size.y <= 0.0 or box.size.z <= 0.0:
					empty_shapes += 1
		elif node is StaticBody3D:
			static_bodies += 1
			var has_shape := false
			for child in node.get_children():
				if child is CollisionShape3D:
					var child_shape := child as CollisionShape3D
					if child_shape.shape != null:
						has_shape = true
			_expect(has_shape, "StaticBody3D %s без коллизии" % node.name)
		elif node is CSGBox3D:
			var csg := node as CSGBox3D
			if csg.use_collision:
				csg_collisions += 1
	_expect(empty_shapes == 0, "пустых/нулевых коллизий: %d" % empty_shapes)
	_expect(csg_collisions == 0, "CSG-коллизий в городе: %d" % csg_collisions)
	_expect(static_bodies >= 100, "StaticBody3D в городе всего %d" % static_bodies)
	var node_count: int = world.get_city_node_count()
	_expect(node_count > 0 and node_count < MAX_CITY_NODES, "узлов города %d" % node_count)
	print("[city-smoke] city: StaticBody3D=%d, узлов=%d, пустых коллизий=%d" % [
		static_bodies, node_count, empty_shapes
	])


func _check_light_budget() -> void:
	var omni := 0
	for node in _all_nodes(world):
		if node is OmniLight3D:
			omni += 1
	_expect(omni <= MAX_OMNI_LIGHTS, "OmniLight3D слишком много: %d (бюджет %d)" % [
		omni, MAX_OMNI_LIGHTS
	])
	_expect(omni == EXPECTED_OMNI_LIGHTS, "OmniLight3D: %d (ожидается %d после T48)" % [
		omni, EXPECTED_OMNI_LIGHTS
	])
	print("[city-smoke] omni lights: %d (ожидается %d, бюджет %d)" % [
		omni, EXPECTED_OMNI_LIGHTS, MAX_OMNI_LIGHTS
	])


# --- Инфраструктура ---------------------------------------------------------


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, COLLISION_MASK)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return space.intersect_ray(query)


func _all_nodes(root_node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child in root_node.get_children():
		result.append(child)
		result.append_array(_all_nodes(child))
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("CITY SMOKE OK: bounds≥350, POI≥8, кольцо замкнуто, дыр нет, коллизии чистые")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("[city-smoke] " + failure)
	print("CITY SMOKE FAILED (%d): %s" % [
		failures.size(), "; ".join(PackedStringArray(failures))
	])
	get_tree().quit(1)
