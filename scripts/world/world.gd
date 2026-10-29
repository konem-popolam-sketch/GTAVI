extends Node3D
## NIGHT SHIFT — ночной квартал: окружение, уличный свет, точки интереса.
##
## Вся геометрия исторического центра лежит в этой же сцене (scenes/world/block.tscn).
## В T32 вокруг центра процедурно строится город: сетка улиц 360×358 м, кварталы
## с домами 4–12 этажей, фонари, разметка. Скрипт отвечает за «живой» свет
## (мерцание фонарей и неона) и даёт интегратору стабильный API:
##   get_spawn_transform()      — трансформ, куда ставить игрока
##   get_poi(StringName)        — мировая позиция точки интереса
##   get_npc_slot(StringName)   — мировая позиция слота NPC
##   get_poi_names()            — отсортированные имена всех POI
##   get_npc_slot_names()       — отсортированные имена всех слотов NPC
##   get_poi_area(StringName)   — район точки интереса (shop, club, garage…)
##   get_walk_route(StringName) — пешеходный маршрут от спавна до POI (для QA)
##   get_road_path()            — замкнутое кольцо по улицам для машины
##   get_city_bounds()          — AABB всего города (для QA и камеры)
##   dump_world_summary()       — печать сводки мира в лог (headless-проверка)
##
## Район расширен в T18: второй переулок, задний проход между домами, внутренний
## двор, крыша магазина, тамбур «Луны», бетонный спуск к воде и нижний причал.
## Город T32: исторический центр сохранён как есть, к северу — сетка 5×5
## кварталов между улицами шириной 10 м; выход из центра — ворота в северной
## стене (x = 0, z = −26.4).
## Старые POI/слоты (POI_Shop, POI_Pier, POI_Fence, POI_Alley, NPC_Mila,
## NPC_Foreman, NPC_Kostya, NPC_Phone) сохранены без переименований.
##
## Запуск сводки: godot --headless --path . -- --dump-world

@export_group("Living light")
## Мерцание уличных фонарей (узлы в группе "street_lamp").
@export var lamp_flicker_enabled: bool = true
## Амплитуда мерцания: 0.0 — ровный свет, 0.15 — заметное гудение лампы.
@export_range(0.0, 0.5, 0.01) var flicker_amount: float = 0.06
## Пульсация неоновой вывески «Луна» (узлы в группе "neon_sign").
@export var neon_pulse_enabled: bool = true

const SPAWN_PATH := "Markers/PlayerSpawn"
const POI_PATH := "PointsOfInterest/%s"
const NPC_PATH := "Markers/NpcSlots/%s"

# --- T32: город вокруг исторического центра ---------------------------------

## Материалы города (существующие PBR-ресурсы; новые не создаются).
const MAT_ASPHALT := preload("res://assets/materials/asphalt_pbr.tres")
const MAT_CONCRETE := preload("res://assets/materials/concrete_pbr.tres")
const MAT_BRICK_RED := preload("res://assets/materials/brick_red_pbr.tres")
const MAT_BRICK_GREY := preload("res://assets/materials/brick_grey_pbr.tres")
const MAT_PLASTER := preload("res://assets/materials/plaster_pbr.tres")
const MAT_ROOF := preload("res://assets/materials/roof_pbr.tres")
const MAT_WINDOW := preload("res://assets/materials/window_warm.tres")
const MAT_DARK := preload("res://assets/materials/sign_dark.tres")
const MAT_DOOR := preload("res://assets/materials/door_glass.tres")
const MAT_METAL := preload("res://assets/materials/metal_pbr.tres")
const MAT_MARKINGS := preload("res://assets/materials/markings.tres")
const MAT_NEON := preload("res://assets/materials/neon_magenta.tres")
const MAT_NEON_CYAN := preload("res://assets/materials/neon_cyan.tres")
const MAT_LAMP := preload("res://assets/materials/lamp_glass.tres")

# --- T44: материалы кварталов, окна и витрины из docs/art/README.md §10 ------
const MAT_FACADE_RESIDENTIAL := preload("res://assets/materials/city_facade_residential.tres")
const MAT_FACADE_COMMERCIAL := preload("res://assets/materials/city_facade_commercial.tres")
const MAT_FACADE_INDUSTRIAL := preload("res://assets/materials/city_facade_industrial.tres")
const MAT_FACADE_WATERFRONT := preload("res://assets/materials/city_facade_waterfront.tres")
const MAT_TRIM_STONE := preload("res://assets/materials/city_trim_stone.tres")
const MAT_WIN_WARM_A := preload("res://assets/materials/window_city_warm_a.tres")
const MAT_WIN_WARM_B := preload("res://assets/materials/window_city_warm_b.tres")
const MAT_WIN_COOL := preload("res://assets/materials/window_city_cool.tres")
const MAT_WIN_OFF := preload("res://assets/materials/window_city_off.tres")
const MAT_WIN_WARM_FAR := preload("res://assets/materials/window_city_warm_far.tres")
const MAT_WIN_COOL_FAR := preload("res://assets/materials/window_city_cool_far.tres")
const MAT_STORE_WARM := preload("res://assets/materials/storefront_glass_warm.tres")
const MAT_STORE_COOL := preload("res://assets/materials/storefront_glass_cool.tres")
const MAT_STORE_SHUTTER := preload("res://assets/materials/storefront_shutter.tres")
const MAT_STORE_ROLL_GATE := preload("res://assets/materials/storefront_roll_gate.tres")
const MAT_SIGN_NEON := preload("res://assets/materials/sign_neon_white.tres")
const MAT_SIGN_PAINTED := preload("res://assets/materials/sign_painted.tres")
const MAT_AWNING := preload("res://assets/materials/awning_canvas.tres")
# T50: интерьерный задник клуба
const MAT_BAR_WOOD := preload("res://assets/materials/bar_counter_wood.tres")
const MAT_INTERIOR_DARK := preload("res://assets/materials/interior_wall_dark.tres")
const MAT_NEON_STRIP := preload("res://assets/materials/neon_strip_magenta.tres")

## Окна: размер квада и шаг из docs/art/README.md §10.2 (не масштабировать!).
const CITY_WINDOW_SIZE := Vector2(1.1, 1.5)
const CITY_WINDOW_STEP_X := 2.4
const CITY_WINDOW_STEP_Y := 3.2
const CITY_WINDOW_SILL := 0.9
const CITY_WINDOW_EDGE := 0.8
## Дальний LOD окон начинается с этой дистанции от центра (м).
const CITY_WINDOW_FAR_DISTANCE := 80.0

## Границы нового города (исторический центр примыкает с юга; вода — южнее).
const CITY_MIN := Vector3(-180.0, -2.0, -390.0)
const CITY_SIZE := Vector3(360.0, 40.0, 358.0)
const CITY_GROUND_THICKNESS := 0.6
const CITY_BLOCK_TOP := 0.15      # тротуары/кварталы: бордюр 0.15 м
const CITY_ROAD_TOP := 0.0        # проезжая часть
const CITY_ROAD_HALF := 5.0       # улица 10 м, две полосы

## Вертикальные улицы (центры по X) и горизонтальные (центры по Z).
const CITY_VROADS := [-120.0, -40.0, 40.0, 120.0]
const CITY_HROADS := [-40.0, -110.0, -180.0, -250.0, -320.0]
## Отрезки улиц между перекрёстками (без наложений).
const CITY_VSEGMENTS := [
	Vector2(-390.0, -325.0), Vector2(-315.0, -255.0), Vector2(-245.0, -185.0),
	Vector2(-175.0, -115.0), Vector2(-105.0, -45.0),
]
const CITY_HSEGMENTS := [
	Vector2(-180.0, -125.0), Vector2(-115.0, -45.0), Vector2(-35.0, 35.0),
	Vector2(45.0, 115.0), Vector2(125.0, 180.0),
]
## Кварталы: 5×5 ячеек между улицами (центр в южном ряду — исторический квартал).
const CITY_COLUMNS := [
	Vector2(-180.0, -125.0), Vector2(-115.0, -45.0), Vector2(-35.0, 35.0),
	Vector2(45.0, 115.0), Vector2(125.0, 180.0),
]
const CITY_ROWS := [
	Vector2(-105.0, -45.0), Vector2(-175.0, -115.0), Vector2(-245.0, -185.0),
	Vector2(-315.0, -255.0), Vector2(-390.0, -325.0),
]
## Кольцо для машины: прямоугольник по улицам x = ±120, z = -40…-250.
const ROAD_LOOP_MIN_X := -120.0
const ROAD_LOOP_MAX_X := 120.0
const ROAD_LOOP_SOUTH_Z := -40.0
const ROAD_LOOP_NORTH_Z := -250.0
## Спецкварталы, которые строятся отдельно: индекс = ряд * 5 + колонка
## (клуб — колонка 2, ряд 0; гараж — 3, 0; заправка — 1, 1).
const CITY_SPECIAL_BLOCKS := [2, 3, 6]

## Район, к которому относится точка интереса. Ключи — имена узлов POI_*.
const POI_AREAS := {
	&"POI_Shop": &"shop",
	&"POI_Pier": &"waterfront",
	&"POI_Fence": &"parking",
	&"POI_Alley": &"alley",
	&"POI_ShopPorch": &"shop",
	&"POI_Courtyard": &"courtyard",
	&"POI_BackPassage": &"back_passage",
	&"POI_Alley2": &"alley2",
	&"POI_Rooftop": &"rooftop",
	&"POI_WaterStairs": &"waterfront",
	&"POI_Quay": &"quay",
	&"POI_Club": &"club",
	&"POI_Garage": &"garage",
	&"POI_Fuel": &"fuel",
	&"POI_Bridge": &"waterfront",
	&"POI_Parking": &"parking",
}

## Пешеходные маршруты от PlayerSpawn до POI — промежуточные точки, последняя
## точка (сама POI) добавляется в get_walk_route(). Нужны QA-тесту: он стреляет
## лучом на высоте пояса вдоль каждого сегмента и проверяет, что стен нет.
## Координаты намеренно лежат в открытых проходах (ширина ≥ 1.2 м).
var _poi_walk_routes: Dictionary = {
	&"POI_Shop": [
		Vector3(-4, 0, -6), Vector3(-4, 0, -9), Vector3(-4, 0, -10.6),
	],
	&"POI_ShopPorch": [
		Vector3(-4, 0, -6), Vector3(-4, 0, -9.4),
	],
	&"POI_Pier": [
		Vector3(0, 0, 20.5), Vector3(0, 0, 22.6), Vector3(0, -0.4, 25),
		Vector3(0, -0.7, 27), Vector3(0, -0.7, 33),
	],
	&"POI_Fence": [
		Vector3(-5, 0, 14.2), Vector3(-8.5, 0, 15.5), Vector3(-8.5, 0, 12.5),
	],
	&"POI_Alley": [
		Vector3(3.2, 0, 2), Vector3(4, 0, -6),
	],
	&"POI_Courtyard": [
		Vector3(0, 0, 4), Vector3(-14, 0, 4.2), Vector3(-22, 0, 3),
		Vector3(-26, 0, 0), Vector3(-26, 0, -6), Vector3(-25.6, 0, -11),
	],
	&"POI_BackPassage": [
		Vector3(8, 0, 8), Vector3(14, 0, 6), Vector3(21.5, 0, 5),
		Vector3(21, 0, 0), Vector3(20.9, 0, -10), Vector3(20.9, 0, -21.5),
		Vector3(21, 0, -25.4), Vector3(14, 0, -25.4),
	],
	&"POI_Alley2": [
		Vector3(8, 0, 8), Vector3(14, 0, 6), Vector3(21.5, 0, 5),
		Vector3(21, 0, 0), Vector3(21, 0, -8),
	],
	&"POI_Rooftop": [
		Vector3(3.2, 0, -9), Vector3(2.85, 0, -12.2), Vector3(2.85, 1.5, -15.3),
		Vector3(2.85, 3.6, -19.4), Vector3(2.85, 5.1, -22.25),
		Vector3(2.3, 5.05, -22.6), Vector3(1.2, 5.05, -22.7),
		Vector3(-1, 5.05, -22), Vector3(-4, 5.02, -20),
	],
	&"POI_WaterStairs": [
		Vector3(8, 0, 12), Vector3(11, 0, 17), Vector3(12.25, 0, 19.5),
	],
	&"POI_Quay": [
		Vector3(8, 0, 12), Vector3(11, 0, 17), Vector3(12.25, 0, 20),
		Vector3(12.25, 0.1, 21.5), Vector3(12.25, -0.33, 22.8),
		Vector3(12.25, -0.7, 24.2),
	],
	&"POI_Parking": [
		Vector3(-5, 0, 14.2), Vector3(-8.5, 0, 15.5), Vector3(-8.5, 0, 12.5),
		Vector3(-12, 0, 12), Vector3(-15, 0, 12),
	],
	&"POI_Bridge": [
		Vector3(0, 0, 20.5),
	],
	&"POI_Club": [
		Vector3(8, 0, 8), Vector3(14, 0, 6), Vector3(21.5, 0, 5),
		Vector3(21, 0, 0), Vector3(20.9, 0, -10), Vector3(20.9, 0, -21.5),
		Vector3(21, 0, -25.4), Vector3(14, 0, -25.4), Vector3(8, 0, -25.4),
		Vector3(2, 0, -25.4), Vector3(0, 0, -26.4), Vector3(0, 0, -29),
		Vector3(0, 0, -33), Vector3(0, 0, -40), Vector3(0, 0.15, -50),
		Vector3(0, 0.15, -60),
	],
	&"POI_Garage": [
		Vector3(8, 0, 8), Vector3(14, 0, 6), Vector3(21.5, 0, 5),
		Vector3(21, 0, 0), Vector3(20.9, 0, -10), Vector3(20.9, 0, -21.5),
		Vector3(21, 0, -25.4), Vector3(14, 0, -25.4), Vector3(8, 0, -25.4),
		Vector3(2, 0, -25.4), Vector3(0, 0, -26.4), Vector3(0, 0, -29),
		Vector3(0, 0, -33), Vector3(0, 0, -40), Vector3(40, 0, -40),
		Vector3(84, 0, -40), Vector3(84, 0.15, -50), Vector3(84, 0.15, -55),
	],
	&"POI_Fuel": [
		Vector3(8, 0, 8), Vector3(14, 0, 6), Vector3(21.5, 0, 5),
		Vector3(21, 0, 0), Vector3(20.9, 0, -10), Vector3(20.9, 0, -21.5),
		Vector3(21, 0, -25.4), Vector3(14, 0, -25.4), Vector3(8, 0, -25.4),
		Vector3(2, 0, -25.4), Vector3(0, 0, -26.4), Vector3(0, 0, -29),
		Vector3(0, 0, -33), Vector3(0, 0, -40), Vector3(-40, 0, -40),
		Vector3(-120, 0, -40), Vector3(-120, 0, -60), Vector3(-120, 0, -80),
		Vector3(-120, 0, -100), Vector3(-120, 0, -110), Vector3(-100, 0, -110),
		Vector3(-80, 0, -110), Vector3(-80, 0.15, -115.5),
	],
}

var _lamps: Array[OmniLight3D] = []
var _lamp_energy: Array[float] = []
var _neon_lights: Array[OmniLight3D] = []
var _neon_energy: Array[float] = []
var _clock: float = 0.0

# --- T32: состояние процедурного города -------------------------------------
var _city_generated: Node3D = null
var _city_batches: Dictionary = {}
var _city_pole_transforms: Array[Transform3D] = []
var _city_bulb_transforms: Array[Transform3D] = []
var _city_unit_box: BoxMesh = null
var _city_pole_mesh: CylinderMesh = null
var _city_bulb_mesh: SphereMesh = null
var _city_body_counter: int = 0
# T44: детали фасадов
var _city_quad_mesh: QuadMesh = null
var _city_houses: Array[Dictionary] = []
var _city_quad_batches: Dictionary = {}
var _city_quad_materials: Dictionary = {}
var _city_last_neon: Dictionary = {}
var _city_store_warm_mat: Material = null
var _city_store_cool_mat: Material = null
var _city_store_glow_mat: Material = null


func _ready() -> void:
	_build_city()
	_collect_lights()
	call_deferred("_update_preview_camera")
	if _has_cmdline_arg("--dump-world"):
		dump_world_summary()


func _process(delta: float) -> void:
	_clock += delta
	_animate_lamps()
	_animate_neon()


# --- Публичный API для интеграции -------------------------------------------


## Трансформ появления игрока: позиция и направление взгляда (Marker3D PlayerSpawn).
func get_spawn_transform() -> Transform3D:
	var marker := get_node_or_null(SPAWN_PATH) as Marker3D
	if marker == null:
		push_warning("[world] PlayerSpawn marker is missing, falling back to plaza")
		return Transform3D(Basis(), Vector3(0.0, 0.2, 10.0))
	return marker.global_transform


## Границы города (исторический центр примыкает с юга, вода — южнее).
func get_city_bounds() -> AABB:
	return AABB(CITY_MIN, CITY_SIZE)


## Замкнутый кольцевой маршрут по улицам для машины (первая и последняя точка
## совпадают). Идёт по осям улиц x = ±120 и z = −40…−250, y = 0 (уровень дороги).
func get_road_path() -> PackedVector3Array:
	var path := PackedVector3Array()
	var z := ROAD_LOOP_SOUTH_Z
	while z > ROAD_LOOP_NORTH_Z:
		path.append(Vector3(ROAD_LOOP_MIN_X, 0.0, z))
		z -= 20.0
	path.append(Vector3(ROAD_LOOP_MIN_X, 0.0, ROAD_LOOP_NORTH_Z))
	var x := ROAD_LOOP_MIN_X
	while x < ROAD_LOOP_MAX_X:
		x += 20.0
		path.append(Vector3(x, 0.0, ROAD_LOOP_NORTH_Z))
	z = ROAD_LOOP_NORTH_Z
	while z < ROAD_LOOP_SOUTH_Z:
		z += 20.0
		if z > ROAD_LOOP_SOUTH_Z:
			z = ROAD_LOOP_SOUTH_Z
		path.append(Vector3(ROAD_LOOP_MAX_X, 0.0, z))
	x = ROAD_LOOP_MAX_X
	while x > ROAD_LOOP_MIN_X:
		x -= 20.0
		if x < ROAD_LOOP_MIN_X:
			x = ROAD_LOOP_MIN_X
		path.append(Vector3(x, 0.0, ROAD_LOOP_SOUTH_Z))
	return path


## Сколько узлов создал процедурный город (для отчёта/QA производительности).
func get_city_node_count() -> int:
	if _city_generated == null:
		return 0
	return _count_nodes_of_type(_city_generated, "Node3D") + 1


## Мировая позиция точки интереса по имени узла (например &"POI_Shop").
func get_poi(poi_name: StringName) -> Vector3:
	var marker := get_node_or_null(POI_PATH % String(poi_name)) as Marker3D
	if marker == null:
		push_warning("[world] Unknown POI: %s" % poi_name)
		return Vector3.ZERO
	return marker.global_position


## Мировая позиция слота NPC (например &"NPC_Mila").
func get_npc_slot(slot_name: StringName) -> Vector3:
	var marker := get_node_or_null(NPC_PATH % String(slot_name)) as Marker3D
	if marker == null:
		push_warning("[world] Unknown NPC slot: %s" % slot_name)
		return Vector3.ZERO
	return marker.global_position


## Имена всех точек интереса (узлы в группе "poi"), по алфавиту.
func get_poi_names() -> PackedStringArray:
	var names: Array[String] = []
	for marker in get_tree().get_nodes_in_group("poi"):
		names.append(String(marker.name))
	names.sort()
	return PackedStringArray(names)


## Имена всех слотов NPC (узлы в группе "npc_slot"), по алфавиту.
func get_npc_slot_names() -> PackedStringArray:
	var names: Array[String] = []
	for marker in get_tree().get_nodes_in_group("npc_slot"):
		names.append(String(marker.name))
	names.sort()
	return PackedStringArray(names)


## Район точки интереса: shop / alley2 / courtyard / rooftop / waterfront / quay.
func get_poi_area(poi_name: StringName) -> StringName:
	var area: StringName = POI_AREAS.get(poi_name, &"unknown")
	return area


## Пешеходный маршрут от спавна до POI. Первая точка — PlayerSpawn, последняя —
## сама POI. Пустой массив, если для POI маршрут не описан.
func get_walk_route(poi_name: StringName) -> PackedVector3Array:
	var route := PackedVector3Array()
	if not _poi_walk_routes.has(poi_name):
		return route
	route.append(get_spawn_transform().origin)
	for point in _poi_walk_routes[poi_name]:
		route.append(point)
	route.append(get_poi(poi_name))
	return route


## Суммарная длина всех описанных пешеходных маршрутов (метры).
func get_total_route_length() -> float:
	var total := 0.0
	for poi_name in _poi_walk_routes.keys():
		var route := get_walk_route(poi_name)
		for i in range(1, route.size()):
			total += route[i - 1].distance_to(route[i])
	return total


## Печатает сводку мира в консоль/лог: пригодится при headless-проверке.
func dump_world_summary() -> void:
	print("[world] NIGHT SHIFT — block summary")
	var top_level := PackedStringArray()
	for child in get_children():
		top_level.append(String(child.name))
	print("[world] top-level nodes (%d): %s" % [top_level.size(), ", ".join(top_level)])
	for poi in get_poi_names():
		var poi_name := StringName(poi)
		print("[world] POI %s [%s] = %s" % [poi, get_poi_area(poi_name), get_poi(poi_name)])
	for slot in get_npc_slot_names():
		print("[world] NPC slot %s = %s" % [slot, get_npc_slot(StringName(slot))])
	print("[world] player spawn = %s" % get_spawn_transform().origin)
	print("[world] omni lights: %d (street lamps %d, neon %d)" % [
		_lamps.size() + _neon_lights.size(), _lamps.size(), _neon_lights.size()
	])
	print("[world] areas: %d POI, %d NPC slots, %d walk routes (%.1f m total)" % [
		get_poi_names().size(), get_npc_slot_names().size(),
		_poi_walk_routes.size(), get_total_route_length()
	])
	print("[world] collision: %d StaticBody3D, %d CollisionShape3D, %d CSG-with-collision" % [
		_count_nodes_of_type(self, "StaticBody3D"),
		_count_nodes_of_type(self, "CollisionShape3D"),
		_count_nodes_of_type(self, "CSGBox3D", "use_collision"),
	])
	var city_bounds := get_city_bounds()
	var road_path := get_road_path()
	print("[world] city: bounds %s size %.0f×%.0f m, road loop %d points (%.0f m), nodes %d" % [
		city_bounds.position, city_bounds.size.x, city_bounds.size.z,
		road_path.size(), _road_path_length(road_path), get_city_node_count()
	])


# --- Внутреннее -------------------------------------------------------------


func _collect_lights() -> void:
	_lamps.clear()
	_lamp_energy.clear()
	for node in get_tree().get_nodes_in_group("street_lamp"):
		var lamp := node as OmniLight3D
		if lamp != null:
			_lamps.append(lamp)
			_lamp_energy.append(lamp.light_energy)
	_neon_lights.clear()
	_neon_energy.clear()
	for node in get_tree().get_nodes_in_group("neon_sign"):
		var light := node as OmniLight3D
		if light != null:
			_neon_lights.append(light)
			_neon_energy.append(light.light_energy)


func _animate_lamps() -> void:
	if not lamp_flicker_enabled:
		return
	for i in _lamps.size():
		var lamp: OmniLight3D = _lamps[i]
		if not is_instance_valid(lamp):
			continue
		var phase: float = float(i) * 1.73
		var wobble: float = sin(_clock * 7.3 + phase) * 0.65 + sin(_clock * 21.0 + phase * 2.1) * 0.35
		lamp.light_energy = _lamp_energy[i] * (1.0 + wobble * flicker_amount)


func _animate_neon() -> void:
	if not neon_pulse_enabled:
		return
	var pulse: float = 0.87 + 0.13 * sin(_clock * 2.1)
	for i in _neon_lights.size():
		var light: OmniLight3D = _neon_lights[i]
		if not is_instance_valid(light):
			continue
		light.light_energy = _neon_energy[i] * pulse


## Обзорная камера живёт только пока в корневой сцене нет Player со своей камерой.
func _update_preview_camera() -> void:
	var main := get_parent()
	if main == null:
		return
	var preview := main.get_node_or_null("PreviewCamera") as Camera3D
	if preview == null:
		return
	preview.current = main.get_node_or_null("Player") == null


## Считает узлы типа type_name в поддереве. Если задан property_name, учитываются
## только узлы, у которых это свойство истинно (например use_collision у CSG).
func _count_nodes_of_type(node: Node, type_name: String, property_name: String = "") -> int:
	var count := 0
	if node.is_class(type_name):
		if property_name.is_empty() or bool(node.get(property_name)):
			count += 1
	for child in node.get_children():
		count += _count_nodes_of_type(child, type_name, property_name)
	return count


# --- T32: процедурный город ---------------------------------------------------


func _build_city() -> void:
	var city := get_node_or_null("City") as Node3D
	if city == null:
		city = Node3D.new()
		city.name = "City"
		add_child(city)
	if city.get_node_or_null("Generated") != null:
		_city_generated = city.get_node("Generated") as Node3D
		return
	_city_generated = Node3D.new()
	_city_generated.name = "Generated"
	city.add_child(_city_generated)
	_city_batches.clear()
	_city_quad_batches.clear()
	_city_quad_materials.clear()
	_city_houses.clear()
	_city_last_neon.clear()
	_city_pole_transforms.clear()
	_city_bulb_transforms.clear()
	_city_body_counter = 0
	_city_unit_box = BoxMesh.new()
	_city_unit_box.size = Vector3.ONE
	_city_quad_mesh = QuadMesh.new()
	_city_quad_mesh.size = Vector2.ONE
	_city_store_warm_mat = _make_storefront_glass(MAT_STORE_WARM as StandardMaterial3D, "warm", 0.26)
	_city_store_cool_mat = _make_storefront_glass(MAT_STORE_COOL as StandardMaterial3D, "cool", 0.28)
	_city_store_glow_mat = _make_storefront_glow()
	_city_quad_materials["store_warm"] = _city_store_warm_mat
	_city_quad_materials["store_cool"] = _city_store_cool_mat
	_city_quad_materials["store_glow"] = _city_store_glow_mat
	_city_pole_mesh = CylinderMesh.new()
	_city_pole_mesh.top_radius = 0.065
	_city_pole_mesh.bottom_radius = 0.11
	_city_pole_mesh.height = 5.2
	_city_pole_mesh.radial_segments = 10
	_city_bulb_mesh = SphereMesh.new()
	_city_bulb_mesh.radius = 0.17
	_city_bulb_mesh.height = 0.34
	_city_bulb_mesh.radial_segments = 10
	_city_bulb_mesh.rings = 5
	_build_city_ground()
	_build_city_blocks()
	_build_city_specials()
	_build_city_facades()
	_build_city_windows()
	_build_city_storefronts()
	_build_city_roofs()
	_build_city_markings()
	_build_city_lamps()
	_build_city_club_crossing_lights()
	_build_city_boundaries()
	_build_city_gate()
	_flush_city_batches()


func _build_city_ground() -> void:
	# Южная площадь между проезжей частью H1 и воротами исторического центра.
	_add_ground_slab(-180.0, 180.0, -35.0, -32.0, CITY_ROAD_TOP, "concrete")
	# Перекрёстки.
	for vx in CITY_VROADS:
		for hz in CITY_HROADS:
			var x: float = vx
			var z: float = hz
			_add_ground_slab(
				x - CITY_ROAD_HALF, x + CITY_ROAD_HALF,
				z - CITY_ROAD_HALF, z + CITY_ROAD_HALF,
				CITY_ROAD_TOP, "asphalt"
			)
	# Вертикальные улицы между перекрёстками.
	for vx in CITY_VROADS:
		var x: float = vx
		for segment in CITY_VSEGMENTS:
			var seg: Vector2 = segment
			_add_ground_slab(
				x - CITY_ROAD_HALF, x + CITY_ROAD_HALF,
				seg.x, seg.y, CITY_ROAD_TOP, "asphalt"
			)
	# Горизонтальные улицы между перекрёстками.
	for hz in CITY_HROADS:
		var z: float = hz
		for segment in CITY_HSEGMENTS:
			var seg: Vector2 = segment
			_add_ground_slab(
				seg.x, seg.y,
				z - CITY_ROAD_HALF, z + CITY_ROAD_HALF,
				CITY_ROAD_TOP, "asphalt"
			)


func _build_city_blocks() -> void:
	for ci in CITY_COLUMNS.size():
		var xr: Vector2 = CITY_COLUMNS[ci]
		for ri in CITY_ROWS.size():
			var zr: Vector2 = CITY_ROWS[ri]
			_add_ground_slab(xr.x, xr.y, zr.x, zr.y, CITY_BLOCK_TOP, "concrete")
			if not _is_special_city_block(ci, ri):
				_fill_city_block(ci, ri, xr, zr)


func _is_special_city_block(ci: int, ri: int) -> bool:
	return CITY_SPECIAL_BLOCKS.has(ri * CITY_COLUMNS.size() + ci)


func _fill_city_block(ci: int, ri: int, xr: Vector2, zr: Vector2) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 + ci * 131 + ri * 17
	var x0: float = xr.x + 6.0
	var x1: float = xr.y - 6.0
	var z0: float = zr.x + 5.0
	var z1: float = zr.y - 5.0
	var w: float = x1 - x0
	var d: float = z1 - z0
	var qx := [x0 + w * 0.25, x0 + w * 0.75]
	var qz := [z0 + d * 0.25, z0 + d * 0.75]
	var skip := rng.randi_range(0, 3)
	var index := 0
	for ix in 2:
		for iz in 2:
			if index == skip:
				index += 1
				continue
			var cx: float = qx[ix]
			var cz: float = qz[iz]
			var bw: float = w * 0.46 * rng.randf_range(0.62, 0.94)
			var bd: float = d * 0.46 * rng.randf_range(0.62, 0.94)
			var floors := rng.randi_range(4, 12)
			_add_city_house(cx, cz, bw, bd, float(floors) * 3.0, rng)
			index += 1


func _add_city_house(cx: float, cz: float, bw: float, bd: float, h: float, rng: RandomNumberGenerator) -> void:
	var base := CITY_BLOCK_TOP
	var center := Vector3(cx, base + h * 0.5, cz)
	_add_collider(center, Vector3(bw, h, bd), "CityHouse")
	_register_city_house(cx, cz, bw, bd, h, rng.randi(), false)
	_batch_box("roof", Vector3(cx, base + h + 0.13, cz), Vector3(bw + 0.5, 0.26, bd + 0.5))


## Запоминает дом для фасадов/окон/витрин. Коллайдер добавляется вызывающим.
func _register_city_house(
	cx: float, cz: float, bw: float, bd: float, h: float,
	seed: int, special: bool, palette_override: String = "",
	manual_facade: bool = false
) -> void:
	var palette := palette_override
	if palette.is_empty():
		palette = _city_facade_palette(cx, cz)
	_city_houses.append({
		"cx": cx,
		"cz": cz,
		"bw": bw,
		"bd": bd,
		"h": h,
		"palette": palette,
		"bucket": _city_size_bucket(h),
		"seed": seed,
		"special": special,
		"manual_facade": manual_facade,
		"street_faces": _city_street_faces(cx, cz, bw, bd),
	})
	# Цоколь 0.6 м и тонкий карниз из city_trim_stone.
	_batch_box("trim", Vector3(cx, CITY_BLOCK_TOP + 0.3, cz), Vector3(bw + 0.16, 0.6, bd + 0.16))
	_batch_box("trim", Vector3(cx, CITY_BLOCK_TOP + h - 0.08, cz), Vector3(bw + 0.22, 0.16, bd + 0.22))


## Палитра квартала: у воды, коммерческая у кольца/южной улицы, складская
## на севере/востоке, остальное — жилая (docs/art/README.md §10.1).
func _city_facade_palette(cx: float, cz: float) -> String:
	if cz >= -110.0 and (cx <= -125.0 or cx >= 125.0):
		return "waterfront"
	if cz >= -110.0:
		return "commercial"
	if (cx >= -115.0 and cx <= -45.0) or (cx >= 45.0 and cx <= 115.0):
		return "commercial"
	if cz <= -300.0 or cx >= 125.0:
		return "industrial"
	return "residential"


## 3 варианта размера дома для разных uv1_scale (малый/средний/большой).
func _city_size_bucket(h: float) -> int:
	if h <= 15.0:
		return 0
	if h <= 27.0:
		return 1
	return 2


## Фасады, выходящие на главные улицы: южная z=-40 (ряд 0), западная x=-120,
## восточная x=+120. Только они получают витрины 1-го этажа.
func _city_street_faces(cx: float, cz: float, bw: float, bd: float) -> Array:
	var faces: Array = []
	# Южная улица z = −40: весь ряд 0.
	if cz >= -115.0:
		faces.append("south")
	# Коммерческие кварталы вдоль кольца x = ±120: все дома колонн C1/C3.
	if cx >= -115.0 and cx <= -45.0:
		faces.append("west")
	if cx >= 45.0 and cx <= 115.0:
		faces.append("east")
	return faces


## T44: корпуса домов с материалами city_facade_* по размеру грани.
## Группируем по палитре и 3 размерам (малый/средний/большой), для группы берём
## средний фасад и считаем uv1_scale = размер/4.5 (или /6 для складов).
func _build_city_facades() -> void:
	var groups: Dictionary = {}
	for rec in _city_houses:
		if bool(rec.get("manual_facade", false)):
			continue
		var palette: String = rec["palette"]
		var bucket: int = rec["bucket"]
		var key := "%s_%d" % [palette, bucket]
		if not groups.has(key):
			groups[key] = {
				"palette": palette,
				"w": 0.0,
				"h": 0.0,
				"count": 0,
				"transforms": [],
			}
		var group: Dictionary = groups[key]
		group["w"] = float(group["w"]) + float(rec["bw"])
		group["h"] = float(group["h"]) + float(rec["h"])
		group["count"] = int(group["count"]) + 1
		var transforms: Array = group["transforms"]
		var center := Vector3(
			float(rec["cx"]),
			CITY_BLOCK_TOP + float(rec["h"]) * 0.5,
			float(rec["cz"])
		)
		transforms.append(Transform3D(
			Basis().scaled(Vector3(float(rec["bw"]), float(rec["h"]), float(rec["bd"]))),
			center
		))
	for key in groups.keys():
		var group: Dictionary = groups[key]
		var count := int(group["count"])
		if count <= 0:
			continue
		var material := _city_facade_material(
			String(group["palette"]),
			float(group["w"]) / float(count),
			float(group["h"]) / float(count)
		)
		var transforms: Array = group["transforms"]
		_flush_multimesh(
			"CityFacades_" + String(key), _city_unit_box, material,
			transforms
		)


func _city_facade_material(palette: String, avg_w: float, avg_h: float) -> Material:
	var base := MAT_FACADE_RESIDENTIAL as StandardMaterial3D
	match palette:
		"commercial":
			base = MAT_FACADE_COMMERCIAL as StandardMaterial3D
		"industrial":
			base = MAT_FACADE_INDUSTRIAL as StandardMaterial3D
		"waterfront":
			base = MAT_FACADE_WATERFRONT as StandardMaterial3D
	var tile := 6.0 if palette == "industrial" else 4.5
	var material := base.duplicate() as StandardMaterial3D
	material.resource_name = "city_facade_%s_scaled" % palette
	material.uv1_scale = Vector3(maxf(avg_w, 1.0) / tile, maxf(avg_h, 1.0) / tile, 1.0)
	return material


## T44: окна 1.1×1.5 квадами, без растягивания по этажу. Дальние дома (≥80 м)
## получают отдельные far-материалы (emission ×2.4, ambient off).
func _build_city_windows() -> void:
	for rec in _city_houses:
		var cx: float = rec["cx"]
		var cz: float = rec["cz"]
		var bw: float = rec["bw"]
		var bd: float = rec["bd"]
		var h: float = rec["h"]
		var base := CITY_BLOCK_TOP
		var far: bool = Vector2(cx, cz).length() >= CITY_WINDOW_FAR_DISTANCE
		var street_faces: Array = rec["street_faces"]
		var rng := RandomNumberGenerator.new()
		rng.seed = int(rec["seed"]) * 7 + 13
		for face in ["south", "north", "east", "west"]:
			var fw := bd
			if face == "south" or face == "north":
				fw = bw
			var cols := int(floor((fw - 2.0 * CITY_WINDOW_EDGE - CITY_WINDOW_SIZE.x) / CITY_WINDOW_STEP_X)) + 1
			if cols <= 0:
				continue
			var rows := int(floor(h / CITY_WINDOW_STEP_Y))
			var skip_ground := street_faces.has(face)
			for row in rows:
				if skip_ground and row == 0:
					continue
				var wy := base + CITY_WINDOW_SILL + CITY_WINDOW_SIZE.y * 0.5 + float(row) * CITY_WINDOW_STEP_Y
				if wy + CITY_WINDOW_SIZE.y * 0.5 > base + h - CITY_WINDOW_EDGE:
					continue
				for col in cols:
					var offset := -fw * 0.5 + CITY_WINDOW_EDGE + CITY_WINDOW_SIZE.x * 0.5 \
						+ float(col) * CITY_WINDOW_STEP_X
					if offset + CITY_WINDOW_SIZE.x * 0.5 > fw * 0.5 - CITY_WINDOW_EDGE:
						continue
					var roll := rng.randf()
					var window_key := "win_warm_a"
					if roll < 0.55:
						window_key = "win_warm_a"
					elif roll < 0.80:
						window_key = "win_warm_b"
					elif roll < 0.92:
						window_key = "win_cool"
					else:
						window_key = "win_off"
					if far:
						if window_key == "win_warm_a" or window_key == "win_warm_b":
							window_key = "win_warm_far"
						elif window_key == "win_cool":
							window_key = "win_cool_far"
						else:
							window_key = "win_off"
					var window_position := Vector3(cx, wy, cz)
					var yaw := 0.0
					match face:
						"south":
							window_position = Vector3(cx + offset, wy, cz + bd * 0.5 + 0.04)
						"north":
							window_position = Vector3(cx + offset, wy, cz - bd * 0.5 - 0.04)
							yaw = PI
						"east":
							window_position = Vector3(cx + bw * 0.5 + 0.04, wy, cz + offset)
							yaw = PI * 0.5
						"west":
							window_position = Vector3(cx - bw * 0.5 - 0.04, wy, cz + offset)
							yaw = -PI * 0.5
					_batch_quad(
						window_key, window_position, yaw,
						CITY_WINDOW_SIZE.x, CITY_WINDOW_SIZE.y
					)


## T44: витрины/вывески/маркизы только 1-го этажа главных улиц.
func _build_city_storefronts() -> void:
	for rec in _city_houses:
		if bool(rec["special"]):
			continue
		var street_faces: Array = rec["street_faces"]
		for face in street_faces:
			_add_storefront_face(rec, String(face))
	_add_club_storefronts()
	_add_garage_storefronts()


func _add_storefront_face(rec: Dictionary, face: String) -> void:
	var cx: float = rec["cx"]
	var cz: float = rec["cz"]
	var bw: float = rec["bw"]
	var bd: float = rec["bd"]
	var base := CITY_BLOCK_TOP
	var fw := bd
	if face == "south" or face == "north":
		fw = bw
	# Широкие бухты 4.5–6 м с шагом 0.4 между ними.
	var count := maxi(1, int(floor((fw - 1.2 + 0.4) / 5.2)))
	while count > 1 and float(count) * 4.5 + float(count - 1) * 0.4 > fw - 1.2:
		count -= 1
	var bay_w := (fw - 1.2 - float(count - 1) * 0.4) / float(count)
	bay_w = clampf(bay_w, 4.5, 6.0)
	if bay_w > fw - 1.2:
		bay_w = fw - 1.2
	var total := float(count) * bay_w + float(count - 1) * 0.4
	var start := -total * 0.5 + bay_w * 0.5
	var rng := RandomNumberGenerator.new()
	var face_seed := 0
	match face:
		"north":
			face_seed = 1
		"east":
			face_seed = 2
		"west":
			face_seed = 3
	rng.seed = int(rec["seed"]) * 13 + face_seed * 997
	var palette := String(rec["palette"])
	for module in count:
		var along := start + float(module) * (bay_w + 0.4)
		var mode := "glass"
		if palette == "industrial":
			mode = "roll"
		elif rng.randf() < 0.25:
			mode = "shutter"
		var cool := rng.randf() < 0.3
		var neon_allowed := false
		if palette != "industrial":
			var along_abs := cx + along
			if face == "east" or face == "west":
				along_abs = cz + along
			var street_key := "south"
			if face == "east" or face == "west":
				street_key = face
			neon_allowed = _allow_neon_sign(street_key, along_abs, rng)
		_add_storefront_bay(
			face, cx, cz, bw, bd, along, bay_w, mode, cool, rng,
			module % 2 == 0, neon_allowed
		)


## Одна витринная бухта: секции стекла + импосты, рама/цоколь, подсвет,
## маркиза через одну и короб вывески. Для клуба параметры секций задаются явно
## (3 секции 0.95×2.4, импост 0.08, дверь 1.0×2.4).
func _add_storefront_bay(
	face: String, cx: float, cz: float, bw: float, bd: float,
	along: float, bay_w: float, mode: String, cool: bool,
	rng: RandomNumberGenerator, awning: bool, neon_allowed: bool,
	sections: int = 0, section_w: float = 1.25, section_h: float = 2.3,
	impost: float = 0.10, sill: float = 0.4, interior_glow: bool = true,
	shutter_section: int = -1, glow_offset: float = 0.04
) -> void:
	var base := CITY_BLOCK_TOP
	var yaw := _facade_yaw(face)
	var glass_key := "store_warm"
	if mode == "roll":
		glass_key = "store_roll"
	elif mode == "shutter":
		glass_key = "store_shutter"
	elif cool:
		glass_key = "store_cool"
	if mode == "roll":
		# Роллет — одна широкая панель, без секций.
		_batch_quad(
			glass_key, _facade_position(face, cx, cz, bw, bd, along, 0.14, base + 1.62),
			yaw, bay_w, 2.9
		)
	else:
		if sections <= 0:
			sections = maxi(1, int(floor((bay_w - 0.2 + impost) / (section_w + impost))))
		var total := float(sections) * section_w + float(sections - 1) * impost
		var first := -total * 0.5 + section_w * 0.5
		for index in sections:
			var section_along := along + first + float(index) * (section_w + impost)
			var section_key := glass_key
			if index == shutter_section:
				section_key = "store_shutter"
			# В клубе один сегмент закрыт жалюзи (shutter_section).
			_batch_quad(
				section_key,
				_facade_position(
					face, cx, cz, bw, bd, section_along,
					0.14, base + sill + section_h * 0.5
				),
				yaw, section_w, section_h
			)
			if mode == "glass" and interior_glow and index != shutter_section:
				_batch_quad(
					"store_glow",
					_facade_position(
						face, cx, cz, bw, bd, section_along,
						glow_offset, base + sill + section_h * 0.5
					),
					yaw, maxf(section_w - 0.1, 0.8), maxf(section_h - 0.25, 1.2)
				)
			if index > 0:
				_facade_box(
					face, cx, cz, bw, bd,
					section_along - section_w * 0.5 - impost * 0.5,
					0.17, base + sill + section_h * 0.5,
					impost, section_h + 0.1, 0.18, "trim"
				)
		# Рама бухты и импост-разделители.
		var frame_total := total
		_facade_box(
			face, cx, cz, bw, bd, along - frame_total * 0.5 - 0.02,
			0.16, base + sill + section_h * 0.5, 0.08, section_h + 0.2, 0.20, "trim"
		)
		_facade_box(
			face, cx, cz, bw, bd, along + frame_total * 0.5 + 0.02,
			0.16, base + sill + section_h * 0.5, 0.08, section_h + 0.2, 0.20, "trim"
		)
		_facade_box(
			face, cx, cz, bw, bd, along, 0.17,
			base + sill + section_h + 0.1, frame_total + 0.24, 0.16, 0.22, "trim"
		)
	# Цоколь 0.4 м под витриной.
	_facade_box(face, cx, cz, bw, bd, along, 0.18, base + 0.2, bay_w, 0.4, 0.34, "trim")
	if awning:
		_facade_box(face, cx, cz, bw, bd, along, 0.62, base + 3.48, bay_w + 0.3, 0.08, 1.25, "awning")
	# Короб вывески и лицевая панель.
	_facade_box(face, cx, cz, bw, bd, along, 0.2, base + 3.98, bay_w * 0.72, 0.8, 0.14, "trim")
	var sign_key := "sign_painted"
	if neon_allowed and mode == "glass":
		sign_key = "sign_neon"
	_batch_quad(
		sign_key,
		_facade_position(face, cx, cz, bw, bd, along, 0.3, base + 3.98),
		yaw, bay_w * 0.64, 0.58
	)

func _facade_yaw(face: String) -> float:
	match face:
		"north":
			return PI
		"east":
			return PI * 0.5
		"west":
			return -PI * 0.5
	return 0.0


func _facade_position(
	face: String, cx: float, cz: float, bw: float, bd: float,
	along: float, outward: float, y: float
) -> Vector3:
	match face:
		"south":
			return Vector3(cx + along, y, cz + bd * 0.5 + outward)
		"north":
			return Vector3(cx + along, y, cz - bd * 0.5 - outward)
		"east":
			return Vector3(cx + bw * 0.5 + outward, y, cz + along)
		"west":
			return Vector3(cx - bw * 0.5 - outward, y, cz + along)
	return Vector3(cx, y, cz)


func _facade_box(
	face: String, cx: float, cz: float, bw: float, bd: float,
	along: float, outward: float, y: float,
	width_along: float, height: float, depth: float, batch_key: String
) -> void:
	var size := Vector3(width_along, height, depth)
	if face == "east" or face == "west":
		size = Vector3(depth, height, width_along)
	_batch_box(batch_key, _facade_position(face, cx, cz, bw, bd, along, outward, y), size)


func _allow_neon_sign(street_key: String, along: float, rng: RandomNumberGenerator) -> bool:
	var last: float = float(_city_last_neon.get(street_key, -1000.0))
	if absf(along - last) < 50.0:
		return false
	if rng.randf() > 0.55:
		return false
	_city_last_neon[street_key] = along
	return true


func _add_club_storefronts() -> void:
	# 2 модуля по 3.2 м на южном фасаде (по 3 секции 0.95×2.4 + дверь 1.0×2.4),
	# плюс третий модуль на восточном фасаде. Один сегмент — жалюзи.
	var rng := RandomNumberGenerator.new()
	rng.seed = 4401 * 13 + 7
	_add_storefront_bay(
		"south", 0.0, -72.0, 12.0, 12.0, -2.9, 3.2, "glass", false, rng,
		true, false, 3, 0.95, 2.4, 0.08, 0.4, true, 0, -1.2
	)
	_add_storefront_bay(
		"south", 0.0, -72.0, 12.0, 12.0, 2.9, 3.2, "glass", false, rng,
		false, false, 3, 0.95, 2.4, 0.08, 0.4, true, -1, -1.2
	)
	# Два витринных Omni из t48 перевешены внутрь ниши (бюджет 58/60).
	_add_club_shop_light(Vector3(2.2, CITY_BLOCK_TOP + 1.9, -67.0), 1.2, 3.5)
	_add_club_shop_light(Vector3(3.4, CITY_BLOCK_TOP + 1.9, -67.0), 0.9, 4.0)
	# Дверная рама 1.0×2.4 (сам полотно двери — в block.tscn).
	_facade_box("south", 0.0, -72.0, 12.0, 12.0, -0.55, 0.16, 1.35, 0.08, 2.5, 0.2, "trim")
	_facade_box("south", 0.0, -72.0, 12.0, 12.0, 0.55, 0.16, 1.35, 0.08, 2.5, 0.2, "trim")
	_facade_box("south", 0.0, -72.0, 12.0, 12.0, 0.0, 0.16, 2.62, 1.25, 0.12, 0.2, "trim")


func _add_club_shop_light(pos: Vector3, energy: float = 0.9, light_range: float = 4.0) -> void:
	var light := OmniLight3D.new()
	light.name = "ClubShopLight"
	light.position = pos
	light.light_color = Color(1.0, 0.72, 0.44, 1.0)  # ≈2700 K
	light.light_energy = energy
	light.light_indirect_energy = 0.3
	light.omni_range = light_range
	light.shadow_enabled = false
	_city_generated.add_child(light)


func _add_garage_storefronts() -> void:
	var base := CITY_BLOCK_TOP
	# Роллет 12×5.6 + рама и вывеска над ним.
	_batch_quad("store_roll", Vector3(84.0, base + 2.8, -64.88), 0.0, 12.0, 5.6)
	_facade_box("south", 84.0, -70.0, 16.0, 10.0, 0.0, 0.14, base + 5.72, 12.4, 0.24, 0.26, "trim")
	_facade_box("south", 84.0, -70.0, 16.0, 10.0, -6.1, 0.14, base + 2.8, 0.25, 5.7, 0.24, "trim")
	_facade_box("south", 84.0, -70.0, 16.0, 10.0, 6.1, 0.14, base + 2.8, 0.25, 5.7, 0.24, "trim")
	_facade_box("south", 84.0, -70.0, 16.0, 10.0, 0.0, 0.2, base + 0.075, 12.3, 0.15, 0.35, "trim")
	var sign_yaw := 0.0
	_batch_quad("sign_painted", Vector3(84.0, base + 6.35, -64.84), sign_yaw, 3.2, 0.8)


## T48: крыши — парапет 0.4 м по периметру, венттрубы/будки, разные силуэты.
## Всё визуал в существующие MultiMesh-группы, без коллайдеров.
func _build_city_roofs() -> void:
	for rec in _city_houses:
		var cx: float = rec["cx"]
		var cz: float = rec["cz"]
		var bw: float = rec["bw"]
		var bd: float = rec["bd"]
		var roof_y := CITY_BLOCK_TOP + float(rec["h"])
		# Парапет 0.4 м по периметру.
		_batch_box("trim", Vector3(cx, roof_y + 0.2, cz + bd * 0.5 - 0.12), Vector3(bw, 0.4, 0.24))
		_batch_box("trim", Vector3(cx, roof_y + 0.2, cz - bd * 0.5 + 0.12), Vector3(bw, 0.4, 0.24))
		_batch_box("trim", Vector3(cx + bw * 0.5 - 0.12, roof_y + 0.2, cz), Vector3(0.24, 0.4, bd))
		_batch_box("trim", Vector3(cx - bw * 0.5 + 0.12, roof_y + 0.2, cz), Vector3(0.24, 0.4, bd))
		var rng := RandomNumberGenerator.new()
		rng.seed = int(rec["seed"]) * 31 + 5
		var vents := 1 + rng.randi_range(0, 1)
		for i in vents:
			var vx := cx + rng.randf_range(-bw * 0.28, bw * 0.28)
			var vz := cz + rng.randf_range(-bd * 0.28, bd * 0.28)
			if i == 0:
				_batch_box("metal", Vector3(vx, roof_y + 0.6, vz), Vector3(0.35, 1.2, 0.35))
				_batch_box("metal", Vector3(vx, roof_y + 1.22, vz), Vector3(0.55, 0.08, 0.55))
			else:
				_batch_box("roof", Vector3(vx, roof_y + 0.32, vz), Vector3(0.9, 0.6, 0.9))
				_batch_box("metal", Vector3(vx, roof_y + 0.72, vz), Vector3(0.22, 0.5, 0.22))
		# Разные высоты в группе: часть домов получает надстройку-будку.
		if rng.randf() < 0.4:
			var bulkhead := Vector3(
				cx + bw * 0.2,
				roof_y + 0.8,
				cz - bd * 0.2
			)
			_batch_box("concrete", bulkhead, Vector3(2.4, 1.6, 2.0))
			_batch_box("metal", Vector3(bulkhead.x, bulkhead.y + 0.85, bulkhead.z), Vector3(2.5, 0.1, 2.1))


func _make_storefront_glass(base: StandardMaterial3D, label: String, emission: float) -> Material:
	var material := base.duplicate() as StandardMaterial3D
	material.resource_name = "storefront_glass_%s_t48" % label
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var color := material.albedo_color
	color.a = 0.35
	material.albedo_color = color
	material.emission_energy_multiplier = emission
	return material


func _make_storefront_glow() -> Material:
	var material := (MAT_WIN_WARM_B as StandardMaterial3D).duplicate() as StandardMaterial3D
	material.resource_name = "storefront_glow_t48"
	material.albedo_color = Color(0.14, 0.10, 0.065, 1.0)
	material.emission_enabled = true
	material.emission = Color(0.95, 0.80, 0.60, 1.0)
	material.emission_energy_multiplier = 1.1
	return material


func _batch_quad(batch_key: String, position: Vector3, yaw: float, width: float, height: float) -> void:
	if not _city_quad_batches.has(batch_key):
		_city_quad_batches[batch_key] = []
	var transforms: Array = _city_quad_batches[batch_key]
	var basis := Basis(Vector3.UP, yaw) * Basis().scaled(Vector3(width, height, 1.0))
	transforms.append(Transform3D(basis, position))


func _flush_quad_batches() -> void:
	for key in _city_quad_batches.keys():
		var material := _material_for_quad_batch(String(key))
		if material == null:
			continue
		var transforms: Array = _city_quad_batches[key]
		_flush_multimesh(
			"CityQuads_" + String(key), _city_quad_mesh, material,
			transforms
		)


func _build_city_specials() -> void:
	_build_city_club()
	_build_city_garage()
	_build_city_fuel()


func _build_city_club() -> void:
	var base := CITY_BLOCK_TOP
	var center := Vector3(0.0, base + 6.0, -72.0)
	_add_collider(center, Vector3(12.0, 12.0, 12.0), "ClubHQ")
	_register_city_house(0.0, -72.0, 12.0, 12.0, 12.0, 4401, true, "commercial", true)
	# T50: фасад клуба собираем вручную — ground floor открыт для ниши за витриной.
	# Верхние этажи и боковые/задняя стены — из батча facade_club (один узел).
	_batch_box("facade_club", Vector3(0.0, base + 7.75, -72.0), Vector3(12.0, 8.8, 12.0))
	_batch_box("facade_club", Vector3(-5.85, base + 1.675, -72.0), Vector3(0.3, 3.35, 12.0))
	_batch_box("facade_club", Vector3(5.85, base + 1.675, -72.0), Vector3(0.3, 3.35, 12.0))
	_batch_box("facade_club", Vector3(0.0, base + 1.675, -77.85), Vector3(12.0, 3.35, 0.3))
	# Тёмная ниша за стеклом: задник в 1.35 м от фасада, пол, потолок.
	_batch_box("interior_dark", Vector3(0.0, base + 1.6, -67.45), Vector3(11.4, 3.2, 0.2))
	_batch_box("interior_dark", Vector3(0.0, base + 3.2, -72.0), Vector3(11.4, 0.08, 11.4))
	_batch_box("interior_dark", Vector3(0.0, base + 0.03, -72.0), Vector3(11.4, 0.06, 11.4))
	# Силуэты интерьера: барная стойка, две полки, стулья, неоновая полоса.
	_batch_box("bar_wood", Vector3(0.0, base + 0.55, -66.85), Vector3(4.2, 1.1, 0.55))
	_batch_box("metal", Vector3(0.0, base + 2.35, -67.05), Vector3(3.8, 0.08, 0.25))
	_batch_box("metal", Vector3(0.0, base + 1.85, -67.05), Vector3(3.8, 0.08, 0.25))
	_batch_box("interior_dark", Vector3(-1.5, base + 0.3, -66.55), Vector3(0.5, 0.6, 0.5))
	_batch_box("interior_dark", Vector3(1.5, base + 0.3, -66.55), Vector3(0.5, 0.6, 0.5))
	_batch_box("neon_strip", Vector3(0.0, base + 2.72, -67.0), Vector3(4.4, 0.05, 0.06))
	# Полосовой тёплый glow у пола внутри ниши.
	_batch_quad("store_glow", Vector3(0.0, base + 0.28, -66.4), 0.0, 4.4, 0.3)
	# Пара «бутылок»-цилиндров на полках (без коллайдеров).
	for bx in [-1.2, -0.4, 0.4, 1.2]:
		var bottle := CSGCylinder3D.new()
		bottle.name = "ClubBottle"
		bottle.radius = 0.04
		bottle.height = 0.3
		bottle.sides = 8
		bottle.material = MAT_METAL as Material
		bottle.position = Vector3(float(bx), base + 2.55, -67.06)
		_city_generated.add_child(bottle)
	_batch_box("roof", Vector3(0.0, base + 12.13, -72.0), Vector3(12.5, 0.26, 12.5))
	_batch_box("neon", Vector3(0.0, base + 9.2, -65.9), Vector3(10.0, 0.6, 0.12))
	_batch_box("neon_cyan", Vector3(0.0, base + 8.3, -65.9), Vector3(8.0, 0.12, 0.12))
	var label := Label3D.new()
	label.name = "ClubSign"
	label.text = "КЛУБ"
	label.font_size = 96
	label.pixel_size = 0.012
	label.modulate = Color(1.8, 0.32, 1.1, 1.0)
	label.outline_size = 0
	label.position = Vector3(0.0, base + 9.8, -65.7)
	_city_generated.add_child(label)


func _build_city_garage() -> void:
	var base := CITY_BLOCK_TOP
	var center := Vector3(84.0, base + 4.5, -70.0)
	_add_collider(center, Vector3(16.0, 9.0, 10.0), "GarageHQ")
	_register_city_house(84.0, -70.0, 16.0, 10.0, 9.0, 4402, true, "industrial")
	_batch_box("roof", Vector3(84.0, base + 9.13, -70.0), Vector3(16.5, 0.26, 10.5))
	_batch_box("neon_cyan", Vector3(84.0, base + 7.3, -64.9), Vector3(10.0, 0.5, 0.12))
	var label := Label3D.new()
	label.name = "GarageSign"
	label.text = "СЕРВИС"
	label.font_size = 64
	label.pixel_size = 0.012
	label.modulate = Color(0.4, 1.7, 2.0, 1.0)
	label.outline_size = 0
	label.position = Vector3(84.0, base + 8.0, -64.78)
	_city_generated.add_child(label)


func _build_city_fuel() -> void:
	var base := CITY_BLOCK_TOP
	var canopy_center := Vector3(-80.0, base + 4.55, -126.0)
	_add_collider(canopy_center, Vector3(18.0, 0.5, 12.0), "FuelCanopy")
	_batch_box("concrete", canopy_center, Vector3(18.0, 0.5, 12.0))
	for px in [-88.0, -72.0]:
		var pillar_x: float = px
		for pz in [-122.0, -130.0]:
			var pillar_z: float = pz
			var pillar := Vector3(pillar_x, base + 2.3, pillar_z)
			_add_collider(pillar, Vector3(0.4, 4.6, 0.4), "FuelPillar")
			_batch_box("metal", pillar, Vector3(0.4, 4.6, 0.4))
	for pump_x in [-84.0, -76.0]:
		var px_value: float = pump_x
		var pump := Vector3(px_value, base + 0.95, -124.0)
		_add_collider(pump, Vector3(1.2, 1.9, 0.7), "FuelPump")
		_batch_box("dark", pump, Vector3(1.2, 1.9, 0.7))
		_batch_box("metal", Vector3(px_value, base + 1.95, -124.0), Vector3(1.3, 0.12, 0.8))
	var sign_pillar := Vector3(-93.0, base + 2.9, -116.0)
	_add_collider(sign_pillar, Vector3(0.5, 5.8, 0.5), "FuelSign")
	_batch_box("metal", sign_pillar, Vector3(0.5, 5.8, 0.5))
	_batch_box("neon_cyan", Vector3(-93.0, base + 6.0, -116.0), Vector3(0.8, 0.9, 0.8))


func _build_city_markings() -> void:
	# Прерывистая осевая разметка на всех улицах (один MultiMesh).
	for vx in CITY_VROADS:
		var x: float = vx
		var z := -385.0
		while z < -38.0:
			_batch_box("markings", Vector3(x, 0.02, z), Vector3(0.16, 0.03, 3.0))
			z += 12.0
	for hz in CITY_HROADS:
		var z: float = hz
		var x := -175.0
		while x < 175.0:
			_batch_box("markings", Vector3(x, 0.02, z), Vector3(3.0, 0.03, 0.16))
			x += 12.0
	# Пешеходные переходы на перекрёстках: 8 полос на каждый.
	for vx in CITY_VROADS:
		for hz in CITY_HROADS:
			var cx: float = vx
			var cz: float = hz
			for edge_index in 2:
				var edge := -1.0 if edge_index == 0 else 1.0
				for lane in 4:
					_batch_box(
						"markings",
						Vector3(cx - 3.6 + float(lane) * 2.4, 0.025, cz + edge * 3.4),
						Vector3(1.2, 0.03, 0.6)
					)


func _build_city_lamps() -> void:
	# Фонари вдоль кольцевых улиц: шаг ~21 м, свет как у исторических фонарей.
	for i in 9:
		var z := -61.0 - float(i) * 21.0
		_add_city_lamp(Vector3(ROAD_LOOP_MIN_X + 6.5, CITY_BLOCK_TOP, z))
		_add_city_lamp(Vector3(ROAD_LOOP_MAX_X - 6.5, CITY_BLOCK_TOP, z))
	for i in 12:
		var x := ROAD_LOOP_MIN_X + float(i) * (ROAD_LOOP_MAX_X - ROAD_LOOP_MIN_X) / 11.0
		if _is_near_vertical_road(x):
			continue
		_add_city_lamp(Vector3(x, CITY_BLOCK_TOP, ROAD_LOOP_SOUTH_Z - 6.5))
		_add_city_lamp(Vector3(x, CITY_BLOCK_TOP, ROAD_LOOP_NORTH_Z + 6.5))


## T48: свет перекрёстка у клуба — ровно две точки по уточнению арт-директора,
## без теней. Клубные витрины подсвечены отдельными тёплыми Omni (см. выше).
## Было 54 Omni, добавляем 2 + 2 витринных = 58 (лимит 60).
func _build_city_club_crossing_lights() -> void:
	_add_crossing_light(Vector3(0.0, 3.2, -40.0), 3.0, 14.0)
	_add_crossing_light(Vector3(0.0, 3.2, -62.0), 2.4, 12.0)


func _add_crossing_light(pos: Vector3, energy: float, light_range: float) -> void:
	var light := OmniLight3D.new()
	light.name = "ClubCrossingLight"
	light.position = pos
	light.light_color = Color(1.0, 0.74, 0.46, 1.0)
	light.light_energy = energy
	light.light_indirect_energy = 0.4
	light.omni_range = light_range
	light.shadow_enabled = false
	_city_generated.add_child(light)
	light.add_to_group("street_lamp")


func _is_near_vertical_road(x: float) -> bool:
	for vx in CITY_VROADS:
		if absf(x - float(vx)) < 6.5:
			return true
	return false


func _add_city_lamp(pos: Vector3, energy: float = 2.8, shadow_mode: int = -1) -> void:
	_city_pole_transforms.append(Transform3D(Basis(), pos + Vector3(0.0, 2.6, 0.0)))
	_city_bulb_transforms.append(Transform3D(Basis(), pos + Vector3(0.0, 5.2, 0.0)))
	var light := OmniLight3D.new()
	light.position = pos + Vector3(0.0, 5.1, 0.0)
	light.light_color = Color(1.0, 0.72, 0.42, 1.0)
	light.light_energy = energy
	light.light_indirect_energy = 0.6
	light.omni_range = 12.0
	# По умолчанию тени у ближней к центру части кольца; для T48 можно
	# принудительно включить/выключить (1/0), чтобы держать лимит теней.
	if shadow_mode >= 0:
		light.shadow_enabled = shadow_mode == 1
	else:
		light.shadow_enabled = pos.z > -60.0 and absf(pos.x) < 80.0
	_city_generated.add_child(light)
	light.add_to_group("street_lamp")


func _build_city_boundaries() -> void:
	# Низкие парапеты по краю города: игрок и машина не уезжают в пустоту.
	_add_city_boundary(Vector3(-180.0, 0.6, -211.0), Vector3(0.4, 1.2, 358.0))
	_add_city_boundary(Vector3(180.0, 0.6, -211.0), Vector3(0.4, 1.2, 358.0))
	_add_city_boundary(Vector3(0.0, 0.6, -390.0), Vector3(360.0, 1.2, 0.4))
	_add_city_boundary(Vector3(-105.0, 0.6, -32.0), Vector3(150.0, 1.2, 0.4))
	_add_city_boundary(Vector3(105.0, 0.6, -32.0), Vector3(150.0, 1.2, 0.4))


func _add_city_boundary(center: Vector3, size: Vector3) -> void:
	_add_collider(center, size, "CityWall")
	_batch_box("concrete", center, size)


func _build_city_gate() -> void:
	# Ворота в северной стене исторического центра: проём ~5.8 м между домами.
	_add_collider(Vector3(-3.2, 1.7, -26.4), Vector3(0.6, 3.4, 0.6), "GatePillar")
	_add_collider(Vector3(3.2, 1.7, -26.4), Vector3(0.6, 3.4, 0.6), "GatePillar")
	_add_collider(Vector3(0.0, 3.55, -26.4), Vector3(7.0, 0.5, 0.6), "GateLintel")
	_batch_box("concrete", Vector3(-3.2, 1.7, -26.4), Vector3(0.6, 3.4, 0.6))
	_batch_box("concrete", Vector3(3.2, 1.7, -26.4), Vector3(0.6, 3.4, 0.6))
	_batch_box("concrete", Vector3(0.0, 3.55, -26.4), Vector3(7.0, 0.5, 0.6))


func _add_ground_slab(x0: float, x1: float, z0: float, z1: float, top_y: float, batch_key: String) -> void:
	var size := Vector3(x1 - x0, CITY_GROUND_THICKNESS, z1 - z0)
	var center := Vector3(
		(x0 + x1) * 0.5,
		top_y - CITY_GROUND_THICKNESS * 0.5,
		(z0 + z1) * 0.5
	)
	_add_collider(center, size, "CitySlab")
	_batch_box(batch_key, center, size)


func _add_collider(center: Vector3, size: Vector3, label: String = "CityBody") -> void:
	_city_body_counter += 1
	var body := StaticBody3D.new()
	body.name = "%s_%d" % [label, _city_body_counter]
	body.position = center
	_city_generated.add_child(body)
	var shape_node := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	shape_node.shape = shape
	body.add_child(shape_node)


func _batch_box(batch_key: String, center: Vector3, size: Vector3) -> void:
	if not _city_batches.has(batch_key):
		_city_batches[batch_key] = []
	var transforms: Array = _city_batches[batch_key]
	transforms.append(Transform3D(Basis().scaled(size), center))


func _flush_city_batches() -> void:
	for key in _city_batches.keys():
		_flush_batch(String(key))
	_flush_quad_batches()
	_flush_multimesh("CityLampPoles", _city_pole_mesh, MAT_METAL as Material, _city_pole_transforms)
	_flush_multimesh("CityLampBulbs", _city_bulb_mesh, MAT_LAMP as Material, _city_bulb_transforms)


func _flush_batch(batch_key: String) -> void:
	var transforms: Array = _city_batches[batch_key]
	if transforms.is_empty():
		return
	var material := _material_for_batch(batch_key)
	if material == null:
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _city_unit_box
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		var transform: Transform3D = transforms[i]
		multimesh.set_instance_transform(i, transform)
	var instance := MultiMeshInstance3D.new()
	instance.name = "Batch_" + batch_key
	instance.multimesh = multimesh
	instance.material_override = material
	_city_generated.add_child(instance)


func _flush_multimesh(node_name: String, mesh: Mesh, material: Material, transforms: Array) -> void:
	if transforms.is_empty():
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		var transform: Transform3D = transforms[i]
		multimesh.set_instance_transform(i, transform)
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.material_override = material
	_city_generated.add_child(instance)


func _material_for_batch(batch_key: String) -> Material:
	match batch_key:
		"asphalt":
			return MAT_ASPHALT as Material
		"concrete":
			return MAT_CONCRETE as Material
		"brick_red":
			return MAT_BRICK_RED as Material
		"brick_grey":
			return MAT_BRICK_GREY as Material
		"plaster":
			return MAT_PLASTER as Material
		"roof":
			return MAT_ROOF as Material
		"window":
			return MAT_WINDOW as Material
		"dark":
			return MAT_DARK as Material
		"door":
			return MAT_DOOR as Material
		"metal":
			return MAT_METAL as Material
		"markings":
			return MAT_MARKINGS as Material
		"neon":
			return MAT_NEON as Material
		"neon_cyan":
			return MAT_NEON_CYAN as Material
		"trim":
			return MAT_TRIM_STONE as Material
		"awning":
			return MAT_AWNING as Material
		"facade_club":
			return _city_facade_material("commercial", 12.0, 9.0)
		"interior_dark":
			return MAT_INTERIOR_DARK as Material
		"bar_wood":
			return MAT_BAR_WOOD as Material
		"neon_strip":
			return MAT_NEON_STRIP as Material
	return null


func _material_for_quad_batch(batch_key: String) -> Material:
	if _city_quad_materials.has(batch_key):
		var override_material: Material = _city_quad_materials[batch_key]
		return override_material
	match batch_key:
		"win_warm_a":
			return MAT_WIN_WARM_A as Material
		"win_warm_b":
			return MAT_WIN_WARM_B as Material
		"win_cool":
			return MAT_WIN_COOL as Material
		"win_off":
			return MAT_WIN_OFF as Material
		"win_warm_far":
			return MAT_WIN_WARM_FAR as Material
		"win_cool_far":
			return MAT_WIN_COOL_FAR as Material
		"store_warm":
			return MAT_STORE_WARM as Material
		"store_cool":
			return MAT_STORE_COOL as Material
		"store_shutter":
			return MAT_STORE_SHUTTER as Material
		"store_roll":
			return MAT_STORE_ROLL_GATE as Material
		"sign_neon":
			return MAT_SIGN_NEON as Material
		"sign_painted":
			return MAT_SIGN_PAINTED as Material
	return null


func _road_path_length(path: PackedVector3Array) -> float:
	var length := 0.0
	for i in range(1, path.size()):
		length += path[i - 1].distance_to(path[i])
	return length


func _has_cmdline_arg(arg: String) -> bool:
	return OS.get_cmdline_args().has(arg) or OS.get_cmdline_user_args().has(arg)
