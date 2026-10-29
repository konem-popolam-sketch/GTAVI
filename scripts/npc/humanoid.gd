class_name Humanoid
extends MeshInstance3D
## Процедурный человек ≈1.75 м из примитивов (без внешних ассетов).
##
## Иерархия (то, что анимируется):
##   Hips → Spine → Chest → Neck → Head
##   Hips → ThighL → ShinL → FootL   (и R)
##   Chest → UpperArmL → ForearmL → HandL   (и R)
##
## Корень сцены — Hips (MeshInstance3D, меш таза), поэтому узел можно ставить
## туда, где ожидается MeshInstance3D (player.gd читает $Body как MeshInstance3D
## и гасит его материал при близкой камере — см. _sync_fade()).
## Начало координат корня — центр таза (≈0.92 м над землёй): ставьте узел на
## пол, оставив position.y = HIP_HEIGHT; set_height_scale() сам поправит
## position.y под рост.
##
## ПУБЛИЧНЫЙ API:
##   apply_skin(name) -> bool      — палитра одежды/волос + рост из SKINS
##   get_skin_names() -> Array     — доступные палитры
##   set_height_scale(value)       — множитель роста поверх палитры (0.85…1.15)
##   get_hip_height() -> float     — на какой высоте должен стоять корень
##   set_locomotion_enabled(bool)  — выключить авто-анимацию ходьбы
##   play_idle() / play_walk() / play_run()
##   get_current_animation() -> String
##   get_part_count() -> int       — сколько сегментов тела собрано
##   get_animation_player() -> AnimationPlayer
##   set_body_shape(name)          — "auto" / "neutral" / "female" / "male"
##   get_body_shape() -> String    — фактический силуэт (после авто-определения)
##   has_bust() -> bool            — собраны ли сегменты груди (только female)
##
## Анимации создаются кодом (никаких импортов): "idle", "walk", "run".
##
## Силуэт (body_shape) — это НЕ пол персонажа и не одежда: он меняет только
## геометрию торса. Для "female" к узлу Chest добавляются два уплощённых
## скруглённых сегмента (BustL/BustR) тем же материалом, что и куртка.
## Подробности и числа — docs/npc/female_bust.md.

const HIP_HEIGHT: float = 0.92
const THIGH_LENGTH: float = 0.44
const SHIN_LENGTH: float = 0.40
const UPPER_ARM_LENGTH: float = 0.30
const FOREARM_LENGTH: float = 0.26

## Допустимые силуэты. "auto" — определить по npc_id/палитре (см. _resolve_body_shape).
const BODY_SHAPES: Array = ["auto", "neutral", "female", "male"]

## Авто-определение силуэта по npc_id родителя (NPC кладёт npc_id в свойства).
const NPC_BODY_SHAPES: Dictionary = {
	"mila": "female",
	"galya": "female",
	"kostya": "male",
	"foreman": "male",
	"timur": "male",
	"player": "male",
}

## Запасной путь: если npc_id нет (например, humanoid поставлен в сцену напрямую),
## силуэт берётся по палитре скина.
const SKIN_BODY_SHAPES: Dictionary = {
	"mila": "female",
}

## Геометрия женского силуэта: два уплощённых сегмента на груди.
## Радиус 0.062 м при масштабе (1.42, 0.76, 0.66) даёт эллипсоид ~0.176×0.094×0.082 м:
## заметно шире, чем выше, — форма ложится «полкой» по груди и читается линией
## груди, а не двумя шарами. Центр на передней грани торса (z −0.096 при грани
## −0.105) → наружу выступает ~32 мм.
## Сегменты перекрываются по центру на 52 мм (offset.x 0.062 при half-width 0.088)
## и сливаются в единый объём; внешний край (0.150) остаётся внутри ширины торса
## (0.175), поэтому габарит фигуры не меняется.
## Суммарный объём двух сегментов ≈5.7 % от объёма торса (0.35×0.34×0.21) —
## в пределах лимита ±6 %.
const BUST_RADIUS: float = 0.062
const BUST_SCALE: Vector3 = Vector3(1.42, 0.76, 0.66)
## x — половинное расстояние между центрами, y — высота в системе Chest (торс
## 0…0.27), z — вперёд от передней грани торса.
const BUST_OFFSET: Vector3 = Vector3(0.062, 0.088, -0.096)

## Палитры: одежда, кожа, волосы + рост. Цвета подобраны под ночной свет.
const SKINS: Dictionary = {
	"player": {
		"skin": Color(0.74, 0.60, 0.49),
		"jacket": Color(0.17, 0.21, 0.29),
		"pants": Color(0.12, 0.14, 0.19),
		"boots": Color(0.08, 0.08, 0.09),
		"hair": Color(0.09, 0.07, 0.06),
		"height": 1.0,
	},
	"mila": {
		"skin": Color(0.82, 0.68, 0.58),
		"jacket": Color(0.32, 0.11, 0.18),
		"pants": Color(0.10, 0.13, 0.22),
		"boots": Color(0.10, 0.09, 0.10),
		"hair": Color(0.06, 0.05, 0.05),
		"height": 0.96,
	},
	"kostya": {
		"skin": Color(0.70, 0.55, 0.44),
		"jacket": Color(0.20, 0.19, 0.13),
		"pants": Color(0.16, 0.15, 0.13),
		"boots": Color(0.07, 0.06, 0.06),
		"hair": Color(0.32, 0.30, 0.28),
		"height": 1.02,
	},
	"foreman": {
		"skin": Color(0.68, 0.52, 0.40),
		"jacket": Color(0.55, 0.30, 0.06),
		"pants": Color(0.13, 0.16, 0.22),
		"boots": Color(0.09, 0.08, 0.07),
		"hair": Color(0.28, 0.26, 0.24),
		"height": 1.06,
	},
	"npc": {
		"skin": Color(0.72, 0.58, 0.47),
		"jacket": Color(0.18, 0.20, 0.24),
		"pants": Color(0.13, 0.14, 0.17),
		"boots": Color(0.08, 0.08, 0.09),
		"hair": Color(0.10, 0.08, 0.07),
		"height": 1.0,
	},
}

@export var skin_preset: String = "player"
@export_enum("auto", "neutral", "female", "male") var body_shape: String = "auto"
@export_range(0.85, 1.15, 0.01) var height_scale: float = 1.0
@export var animation_enabled: bool = true
@export var walk_speed: float = 4.0
@export var run_speed: float = 7.0
@export var walk_amplitude: float = 1.0
@export var run_amplitude: float = 1.15
@export var fade_sync_enabled: bool = true

var _parts: Array[MeshInstance3D] = []
var _materials: Dictionary = {}
var _base_emission: Dictionary = {}
var _anim_player: AnimationPlayer = null
var _current_anim: String = ""
var _locomotion_enabled: bool = true
var _applied_alpha: float = 1.0
var _preset_height: float = 1.0
var _transparent: bool = false
var _resolved_shape: String = "neutral"
var _bust: Array[MeshInstance3D] = []

# Сегменты, которые двигает анимация.
var spine: Node3D = null
var chest: Node3D = null
var neck: Node3D = null
var head: Node3D = null
var thigh_l: Node3D = null
var thigh_r: Node3D = null
var shin_l: Node3D = null
var shin_r: Node3D = null
var foot_l: Node3D = null
var foot_r: Node3D = null
var upper_arm_l: Node3D = null
var upper_arm_r: Node3D = null
var forearm_l: Node3D = null
var forearm_r: Node3D = null


func _ready() -> void:
	_build_materials()
	_resolved_shape = _resolve_body_shape()
	_build_rig()
	_build_animations()
	apply_skin(skin_preset)
	set_process(animation_enabled or fade_sync_enabled)


func _process(delta: float) -> void:
	if fade_sync_enabled:
		_sync_fade()
	if _locomotion_enabled and animation_enabled:
		_update_locomotion(delta)


# --- Публичный API -----------------------------------------------------------


func get_skin_names() -> Array:
	return SKINS.keys()


func apply_skin(preset: String) -> bool:
	if not SKINS.has(preset):
		preset = "npc"
	skin_preset = preset
	var data: Dictionary = SKINS[preset]
	var skin_color: Color = data["skin"]
	var jacket_color: Color = data["jacket"]
	var pants_color: Color = data["pants"]
	var boots_color: Color = data["boots"]
	var hair_color: Color = data["hair"]
	_materials["skin"].albedo_color = skin_color
	_materials["jacket"].albedo_color = jacket_color
	_materials["pants"].albedo_color = pants_color
	_materials["boots"].albedo_color = boots_color
	_materials["hair"].albedo_color = hair_color
	_materials["skin"].emission = skin_color
	_materials["jacket"].emission = jacket_color
	_materials["pants"].emission = pants_color
	_materials["boots"].emission = boots_color
	_materials["hair"].emission = hair_color
	_preset_height = float(data.get("height", 1.0))
	_refresh_scale()
	return true


func set_height_scale(value: float) -> void:
	height_scale = clampf(value, 0.85, 1.15)
	_refresh_scale()


func get_hip_height() -> float:
	return HIP_HEIGHT * height_scale * _preset_height


func set_locomotion_enabled(value: bool) -> void:
	_locomotion_enabled = value
	if not value:
		play_idle()


func play_idle() -> void:
	_play("idle")


func play_walk() -> void:
	_play("walk")


func play_run() -> void:
	_play("run")


func get_current_animation() -> String:
	return _current_anim


func get_part_count() -> int:
	return _parts.size()


func get_animation_player() -> AnimationPlayer:
	return _anim_player


## Переключить силуэт на ходу (в т.ч. после _ready — геометрия пересобирается).
func set_body_shape(shape_name: String) -> void:
	var wanted: String = String(shape_name).to_lower().strip_edges()
	if not BODY_SHAPES.has(wanted):
		wanted = "neutral"
	body_shape = wanted
	_resolved_shape = _resolve_body_shape()
	if chest == null:
		return  # ещё не собраны — применится в _build_rig()
	_clear_bust()
	if _resolved_shape == "female":
		_build_bust(chest)


## Фактический силуэт после авто-определения: "neutral" / "female" / "male".
func get_body_shape() -> String:
	return _resolved_shape


func has_bust() -> bool:
	return not _bust.is_empty()


# --- Сборка --------------------------------------------------------------


func _refresh_scale() -> void:
	var total: float = height_scale * _preset_height
	scale = Vector3.ONE * total
	position.y = HIP_HEIGHT * total


## "auto" → по npc_id родителя (NPC/Player), иначе по палитре скина.
func _resolve_body_shape() -> String:
	var wanted: String = String(body_shape).to_lower().strip_edges()
	if wanted != "auto":
		return wanted if BODY_SHAPES.has(wanted) else "neutral"
	var npc_id: String = _read_owner_npc_id()
	if NPC_BODY_SHAPES.has(npc_id):
		return String(NPC_BODY_SHAPES[npc_id])
	if SKIN_BODY_SHAPES.has(skin_preset):
		return String(SKIN_BODY_SHAPES[skin_preset])
	# Без опознания: палитры игрока/мужские пресеты — male, прочее — neutral.
	if skin_preset == "player" or skin_preset == "kostya" or skin_preset == "foreman":
		return "male"
	return "neutral"


## Читает npc_id у ближайшего родителя, у которого это свойство объявлено
## (NPC объявляет @export var npc_id; player.gd — нет).
func _read_owner_npc_id() -> String:
	var node: Node = get_parent()
	var guard: int = 0
	while node != null and guard < 3:
		for prop in node.get_property_list():
			if String(prop.get("name", "")) == "npc_id":
				var value: Variant = node.get("npc_id")
				return String(value).strip_edges() if value != null else ""
		node = node.get_parent()
		guard += 1
	return ""


## Два уплощённых сегмента груди. Дети Chest, поэтому повторяют все повороты
## корпуса из idle/walk/run; собственных треков у них нет — значит анимация их
## не деформирует.
func _build_bust(parent: Node3D) -> void:
	for side in ["L", "R"]:
		var sign_x: float = -1.0 if side == "L" else 1.0
		var part := _add_mesh(
			parent,
			"Bust" + side,
			_sphere(BUST_RADIUS),
			"jacket",
			Vector3(BUST_OFFSET.x * sign_x, BUST_OFFSET.y, BUST_OFFSET.z)
		)
		part.scale = BUST_SCALE
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_bust.append(part)


func _clear_bust() -> void:
	for part in _bust:
		_parts.erase(part)
		if is_instance_valid(part):
			part.queue_free()
	_bust.clear()


func _build_materials() -> void:
	var specs := {
		"skin": [Color(0.74, 0.60, 0.49), 0.72, 0.06],
		"jacket": [Color(0.17, 0.21, 0.29), 0.78, 0.05],
		"pants": [Color(0.12, 0.14, 0.19), 0.80, 0.04],
		"boots": [Color(0.08, 0.08, 0.09), 0.62, 0.03],
		"hair": [Color(0.09, 0.07, 0.06), 0.66, 0.03],
		"eye": [Color(0.03, 0.03, 0.04), 0.30, 0.0],
	}
	for key in specs.keys():
		var spec: Array = specs[key]
		var mat := _make_material(spec[0], spec[1], spec[2])
		_materials[key] = mat
		_base_emission[key] = float(spec[2])


func _make_material(color: Color, roughness: float, emission_energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	# Ночью лицо/одежда не должны проваливаться в чёрный: мягкий rim + чуть свечения.
	mat.rim_enabled = true
	mat.rim = 0.35
	mat.rim_tint = 0.7
	mat.emission_enabled = emission_energy > 0.0
	mat.emission = color
	mat.emission_energy_multiplier = emission_energy
	return mat


func _build_rig() -> void:
	# Корень — таз.
	mesh = _box(Vector3(0.30, 0.18, 0.20))
	set_surface_override_material(0, _materials["pants"])
	_parts.append(self)

	spine = _bone(self, "Spine", Vector3(0, 0.12, 0))
	_add_mesh(spine, "Torso", _box(Vector3(0.28, 0.12, 0.19)), "pants", Vector3(0, 0.06, 0))

	chest = _bone(spine, "Chest", Vector3(0, 0.20, 0))
	_add_mesh(chest, "ChestMesh", _box(Vector3(0.35, 0.34, 0.21)), "jacket", Vector3(0, 0.10, 0))
	_add_mesh(chest, "Shoulders", _box(Vector3(0.38, 0.09, 0.22)), "jacket", Vector3(0, 0.245, 0))
	if _resolved_shape == "female":
		_build_bust(chest)

	neck = _bone(chest, "Neck", Vector3(0, 0.24, 0))
	_add_mesh(neck, "NeckMesh", _capsule(0.05, 0.10), "skin", Vector3(0, 0.05, 0))

	head = _bone(neck, "Head", Vector3(0, 0.08, 0))
	_build_head(head)

	_build_leg("L", -0.10)
	_build_leg("R", 0.10)
	_build_arm("L", -0.21)
	_build_arm("R", 0.21)


func _build_head(parent: Node3D) -> void:
	var skull := _add_mesh(parent, "Skull", _sphere(0.115), "skin", Vector3(0, 0.10, 0))
	skull.scale = Vector3(0.94, 1.03, 0.98)
	_add_mesh(parent, "Jaw", _box(Vector3(0.15, 0.09, 0.14)), "skin", Vector3(0, 0.02, -0.02))
	_add_mesh(parent, "Nose", _box(Vector3(0.04, 0.05, 0.05)), "skin", Vector3(0, 0.075, -0.105))
	_add_mesh(parent, "BrowL", _box(Vector3(0.055, 0.014, 0.02)), "hair", Vector3(-0.045, 0.125, -0.10))
	_add_mesh(parent, "BrowR", _box(Vector3(0.055, 0.014, 0.02)), "hair", Vector3(0.045, 0.125, -0.10))
	_add_mesh(parent, "EyeL", _sphere(0.017), "eye", Vector3(-0.045, 0.10, -0.098))
	_add_mesh(parent, "EyeR", _sphere(0.017), "eye", Vector3(0.045, 0.10, -0.098))
	var hair := _add_mesh(parent, "Hair", _sphere(0.12), "hair", Vector3(0, 0.135, 0.018))
	hair.scale = Vector3(1.02, 0.88, 1.02)
	_add_mesh(parent, "SideburnL", _box(Vector3(0.02, 0.05, 0.05)), "hair", Vector3(-0.105, 0.075, -0.01))
	_add_mesh(parent, "SideburnR", _box(Vector3(0.02, 0.05, 0.05)), "hair", Vector3(0.105, 0.075, -0.01))


func _build_leg(side: String, x: float) -> void:
	var thigh := _bone(self, "Thigh" + side, Vector3(x, -0.06, 0))
	_add_mesh(thigh, "ThighMesh", _capsule(0.098, THIGH_LENGTH), "pants", Vector3(0, -THIGH_LENGTH * 0.5, 0))
	var shin := _bone(thigh, "Shin" + side, Vector3(0, -THIGH_LENGTH, 0))
	_add_mesh(shin, "ShinMesh", _capsule(0.072, SHIN_LENGTH), "pants", Vector3(0, -SHIN_LENGTH * 0.5, 0))
	var foot := _bone(shin, "Foot" + side, Vector3(0, -SHIN_LENGTH, 0))
	_add_mesh(foot, "BootMesh", _box(Vector3(0.12, 0.08, 0.25)), "boots", Vector3(0, 0.015, -0.055))
	if side == "L":
		thigh_l = thigh
		shin_l = shin
		foot_l = foot
	else:
		thigh_r = thigh
		shin_r = shin
		foot_r = foot


func _build_arm(side: String, x: float) -> void:
	var upper := _bone(chest, "UpperArm" + side, Vector3(x, 0.20, 0))
	_add_mesh(upper, "UpperArmMesh", _capsule(0.064, UPPER_ARM_LENGTH), "jacket",
		Vector3(0, -UPPER_ARM_LENGTH * 0.5, 0))
	var forearm := _bone(upper, "Forearm" + side, Vector3(0, -UPPER_ARM_LENGTH, 0))
	_add_mesh(forearm, "ForearmMesh", _capsule(0.055, FOREARM_LENGTH), "jacket",
		Vector3(0, -FOREARM_LENGTH * 0.5, 0))
	var hand := _bone(forearm, "Hand" + side, Vector3(0, -FOREARM_LENGTH, 0))
	_add_mesh(hand, "HandMesh", _box(Vector3(0.08, 0.10, 0.055)), "skin", Vector3(0, -0.045, 0))
	if side == "L":
		upper_arm_l = upper
		forearm_l = forearm
	else:
		upper_arm_r = upper
		forearm_r = forearm


func _bone(parent: Node3D, bone_name: String, offset: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = bone_name
	node.position = offset
	parent.add_child(node)
	return node


func _add_mesh(
	parent: Node3D, part_name: String, part_mesh: Mesh, material_key: String, offset: Vector3
) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = part_name
	node.mesh = part_mesh
	node.position = offset
	node.set_surface_override_material(0, _materials[material_key])
	parent.add_child(node)
	_parts.append(node)
	return node


func _box(size: Vector3) -> BoxMesh:
	var box := BoxMesh.new()
	box.size = size
	return box


func _capsule(radius: float, height: float) -> CapsuleMesh:
	var capsule := CapsuleMesh.new()
	capsule.radius = radius
	capsule.height = maxf(height, radius * 2.0 + 0.01)
	capsule.radial_segments = 12
	capsule.rings = 4
	return capsule


func _sphere(radius: float) -> SphereMesh:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 14
	sphere.rings = 7
	return sphere


# --- Анимации --------------------------------------------------------------


func _build_animations() -> void:
	_anim_player = get_node_or_null("AnimationPlayer") as AnimationPlayer
	if _anim_player == null:
		_anim_player = AnimationPlayer.new()
		_anim_player.name = "AnimationPlayer"
		add_child(_anim_player)
	_anim_player.root_node = NodePath("..")

	var library := AnimationLibrary.new()
	library.add_animation("idle", _make_idle())
	library.add_animation("walk", _make_walk())
	library.add_animation("run", _make_run())
	if _anim_player.has_animation_library(""):
		_anim_player.remove_animation_library("")
	_anim_player.add_animation_library("", library)
	_play("idle")


func _play(anim_name: String) -> void:
	if _anim_player == null or not _anim_player.has_animation(anim_name):
		return
	if _current_anim == anim_name and _anim_player.is_playing():
		return
	_current_anim = anim_name
	_anim_player.play(anim_name, 0.2)
	_anim_player.speed_scale = 1.0


func _make_idle() -> Animation:
	var anim := Animation.new()
	anim.length = 3.4
	anim.loop_mode = Animation.LOOP_LINEAR
	# Дыхание: корпус чуть вверх-вниз, плечи качаются, голова медленно ведёт.
	_add_rotation_track(anim, spine, [
		Vector3(0.4, 0.0, 0.0),
		Vector3(1.4, 0.0, 0.0),
		Vector3(0.4, 0.0, 0.0),
	])
	_add_rotation_track(anim, chest, [
		Vector3(0.0, 0.0, 0.6),
		Vector3(-0.6, 0.0, -0.6),
		Vector3(0.0, 0.0, 0.6),
	])
	_add_rotation_track(anim, head, [
		Vector3(0.0, -1.6, 0.0),
		Vector3(1.2, 1.8, 0.0),
		Vector3(0.0, -1.6, 0.0),
	])
	_add_rotation_track(anim, upper_arm_l, [
		Vector3(2.0, 0.0, 3.0),
		Vector3(-1.0, 0.0, 4.2),
		Vector3(2.0, 0.0, 3.0),
	])
	_add_rotation_track(anim, upper_arm_r, [
		Vector3(-1.0, 0.0, -4.2),
		Vector3(2.0, 0.0, -3.0),
		Vector3(-1.0, 0.0, -4.2),
	])
	# Idle обязан вернуть ноги/предплечья в нейтраль, иначе после ходьбы
	# персонаж застывает в последней позе шага (у walk/run свои треки).
	_add_rotation_track(anim, thigh_l, [
		Vector3(0.0, 0.0, 0.0), Vector3(0.7, 0.0, 0.0), Vector3(0.0, 0.0, 0.0),
	])
	_add_rotation_track(anim, thigh_r, [
		Vector3(0.0, 0.0, 0.0), Vector3(-0.7, 0.0, 0.0), Vector3(0.0, 0.0, 0.0),
	])
	_add_rotation_track(anim, shin_l, [
		Vector3(2.0, 0.0, 0.0), Vector3(3.2, 0.0, 0.0), Vector3(2.0, 0.0, 0.0),
	])
	_add_rotation_track(anim, shin_r, [
		Vector3(2.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0),
	])
	_add_rotation_track(anim, forearm_l, [
		Vector3(-6.0, 0.0, 0.0), Vector3(-9.0, 0.0, 0.0), Vector3(-6.0, 0.0, 0.0),
	])
	_add_rotation_track(anim, forearm_r, [
		Vector3(-6.0, 0.0, 0.0), Vector3(-3.0, 0.0, 0.0), Vector3(-6.0, 0.0, 0.0),
	])
	return anim


func _make_walk() -> Animation:
	var amp: float = walk_amplitude
	var anim := Animation.new()
	anim.length = 1.15
	anim.loop_mode = Animation.LOOP_LINEAR
	_add_rotation_track(anim, thigh_l, [
		Vector3(-24.0 * amp, 0.0, 0.0),
		Vector3(22.0 * amp, 0.0, 0.0),
		Vector3(-24.0 * amp, 0.0, 0.0),
	])
	_add_rotation_track(anim, thigh_r, [
		Vector3(22.0 * amp, 0.0, 0.0),
		Vector3(-24.0 * amp, 0.0, 0.0),
		Vector3(22.0 * amp, 0.0, 0.0),
	])
	_add_rotation_track(anim, shin_l, [
		Vector3(6.0, 0.0, 0.0),
		Vector3(34.0 * amp, 0.0, 0.0),
		Vector3(4.0, 0.0, 0.0),
		Vector3(6.0, 0.0, 0.0),
	], [0.0, 0.30, 0.70, 1.15])
	_add_rotation_track(anim, shin_r, [
		Vector3(4.0, 0.0, 0.0),
		Vector3(34.0 * amp, 0.0, 0.0),
		Vector3(6.0, 0.0, 0.0),
		Vector3(4.0, 0.0, 0.0),
	], [0.0, 0.45, 0.95, 1.15])
	_add_rotation_track(anim, upper_arm_l, [
		Vector3(20.0 * amp, 0.0, 4.0),
		Vector3(-18.0 * amp, 0.0, 6.0),
		Vector3(20.0 * amp, 0.0, 4.0),
	])
	_add_rotation_track(anim, upper_arm_r, [
		Vector3(-18.0 * amp, 0.0, -6.0),
		Vector3(20.0 * amp, 0.0, -4.0),
		Vector3(-18.0 * amp, 0.0, -6.0),
	])
	_add_rotation_track(anim, forearm_l, [
		Vector3(-8.0, 0.0, 0.0),
		Vector3(-22.0 * amp, 0.0, 0.0),
		Vector3(-8.0, 0.0, 0.0),
	])
	_add_rotation_track(anim, forearm_r, [
		Vector3(-22.0 * amp, 0.0, 0.0),
		Vector3(-8.0, 0.0, 0.0),
		Vector3(-22.0 * amp, 0.0, 0.0),
	])
	_add_rotation_track(anim, spine, [
		Vector3(3.0, -3.0 * amp, 0.0),
		Vector3(3.0, 3.0 * amp, 0.0),
		Vector3(3.0, -3.0 * amp, 0.0),
	])
	return anim


func _make_run() -> Animation:
	var amp: float = run_amplitude
	var anim := Animation.new()
	anim.length = 0.72
	anim.loop_mode = Animation.LOOP_LINEAR
	_add_rotation_track(anim, thigh_l, [
		Vector3(-42.0 * amp, 0.0, 0.0),
		Vector3(34.0 * amp, 0.0, 0.0),
		Vector3(-42.0 * amp, 0.0, 0.0),
	])
	_add_rotation_track(anim, thigh_r, [
		Vector3(34.0 * amp, 0.0, 0.0),
		Vector3(-42.0 * amp, 0.0, 0.0),
		Vector3(34.0 * amp, 0.0, 0.0),
	])
	_add_rotation_track(anim, shin_l, [
		Vector3(12.0, 0.0, 0.0),
		Vector3(70.0 * amp, 0.0, 0.0),
		Vector3(10.0, 0.0, 0.0),
		Vector3(12.0, 0.0, 0.0),
	], [0.0, 0.18, 0.44, 0.72])
	_add_rotation_track(anim, shin_r, [
		Vector3(10.0, 0.0, 0.0),
		Vector3(70.0 * amp, 0.0, 0.0),
		Vector3(12.0, 0.0, 0.0),
		Vector3(10.0, 0.0, 0.0),
	], [0.0, 0.28, 0.60, 0.72])
	_add_rotation_track(anim, upper_arm_l, [
		Vector3(48.0 * amp, 0.0, 6.0),
		Vector3(-40.0 * amp, 0.0, 8.0),
		Vector3(48.0 * amp, 0.0, 6.0),
	])
	_add_rotation_track(anim, upper_arm_r, [
		Vector3(-40.0 * amp, 0.0, -8.0),
		Vector3(48.0 * amp, 0.0, -6.0),
		Vector3(-40.0 * amp, 0.0, -8.0),
	])
	_add_rotation_track(anim, forearm_l, [
		Vector3(-45.0 * amp, 0.0, 0.0),
		Vector3(-65.0 * amp, 0.0, 0.0),
		Vector3(-45.0 * amp, 0.0, 0.0),
	])
	_add_rotation_track(anim, forearm_r, [
		Vector3(-65.0 * amp, 0.0, 0.0),
		Vector3(-45.0 * amp, 0.0, 0.0),
		Vector3(-65.0 * amp, 0.0, 0.0),
	])
	_add_rotation_track(anim, spine, [
		Vector3(12.0, -5.0 * amp, 0.0),
		Vector3(12.0, 5.0 * amp, 0.0),
		Vector3(12.0, -5.0 * amp, 0.0),
	])
	return anim


## Ключи равномерно раскладываются по длине анимации, если времена не заданы.
func _add_rotation_track(
	anim: Animation, bone: Node3D, values: Array, times: Array = []
) -> void:
	if bone == null:
		return
	var idx: int = anim.add_track(Animation.TYPE_VALUE)
	# Путь трека относителен root_node AnimationPlayer (".." = Hips), поэтому
	# вложенные кости идут вроде "Spine/Chest".
	var rel: NodePath = get_path_to(bone)
	anim.track_set_path(idx, NodePath("%s:rotation_degrees" % String(rel)))
	anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_CUBIC)
	anim.value_track_set_update_mode(idx, Animation.UPDATE_CONTINUOUS)
	var count: int = values.size()
	for i in count:
		var t: float = float(times[i]) if i < times.size() else anim.length * float(i) / float(maxi(count - 1, 1))
		anim.track_insert_key(idx, t, values[i])


# --- Локомоция и затухание --------------------------------------------------


func _update_locomotion(_delta: float) -> void:
	var speed: float = _parent_speed()
	var target := "idle"
	if speed > walk_speed * 1.15:
		target = "run"
	elif speed > 0.25 * walk_speed:
		target = "walk"
	if target != _current_anim:
		_play(target)
	if _anim_player == null:
		return
	match target:
		"walk":
			_anim_player.speed_scale = clampf(speed / maxf(walk_speed, 0.01), 0.65, 1.6)
		"run":
			_anim_player.speed_scale = clampf(speed / maxf(run_speed, 0.01), 0.8, 1.35)
		_:
			_anim_player.speed_scale = 1.0


func _parent_speed() -> float:
	var parent := get_parent()
	if parent is CharacterBody3D:
		return (parent as CharacterBody3D).velocity.length()
	# NPC с компонентом NPCWalker — корень StaticBody3D, скорость берём у него.
	if parent != null and parent.has_method("get_walk_velocity"):
		var walk_velocity: Variant = parent.call("get_walk_velocity")
		if walk_velocity is Vector3:
			return (walk_velocity as Vector3).length()
	return 0.0


## player.gd гасит материал только у корня (таз). Здесь альфа раскидывается
## на все сегменты, чтобы человек исчезал целиком, а не «тазом».
func _sync_fade() -> void:
	var mat := get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		return
	var alpha: float = mat.albedo_color.a
	if is_equal_approx(alpha, _applied_alpha):
		return
	_applied_alpha = alpha
	var transparent_needed: bool = alpha < 0.999
	if transparent_needed != _transparent:
		_transparent = transparent_needed
		for key in _materials.keys():
			var part_mat: StandardMaterial3D = _materials[key]
			part_mat.transparency = (
				BaseMaterial3D.TRANSPARENCY_ALPHA if transparent_needed
				else BaseMaterial3D.TRANSPARENCY_DISABLED
			)
	for key in _materials.keys():
		var part_mat: StandardMaterial3D = _materials[key]
		if part_mat == mat:
			continue
		var color: Color = part_mat.albedo_color
		color.a = alpha
		part_mat.albedo_color = color
		if part_mat.emission_enabled:
			part_mat.emission_energy_multiplier = float(_base_emission[key]) * alpha
