class_name ObjectiveMarker
extends Node3D
## ObjectiveMarker — ненавязчивая подсветка текущей цели.
##
## Это не стрелка над головой: на земле лежит мягкое пятно света, над ним
## медленно пульсирует маленькая точка, а слабый OmniLight подкрашивает
## асфальт. Маркер собирает дочерние узлы сам — интегратору достаточно
## добавить Node3D со скриптом в точку квартала и указать stage_id.
##
## Использование (t20):
##   ObjectiveMarker (script)   position = точка у пирса
##   stage_id = "deliver_package"
## Для каждой стадии можно поставить свой маркер — видимым будет только тот,
## чья stage_id совпадает с QuestState.get_current_stage_id(). Пустой stage_id
## означает «висеть всегда» (например, подсветка входа в «Луну»).
##
## Публичный API:
##   set_active(value); is_active() -> bool
##   set_stage_id(value); get_stage_id() -> String
##   set_marker_color(color)
## Сигналы: marker_shown(stage_id), marker_hidden(stage_id)

signal marker_shown(stage_id: String)
signal marker_hidden(stage_id: String)

@export var stage_id: String = ""
@export var marker_color: Color = Color(0.55, 0.82, 1.0)
## Высота пульсирующей точки над землёй, м.
@export var dot_height: float = 0.55
## Радиус пятна света на земле, м.
@export var ground_radius: float = 0.42
## Энергия OmniLight; 0 — только точка и пятно.
@export var light_energy: float = 0.55
@export var pulse_speed: float = 1.7
@export var pulse_amount: float = 0.16
## Скрывать маркер, когда квест завершён.
@export var hide_when_finished: bool = true

var _active: bool = true
var _dot: MeshInstance3D = null
var _ground: MeshInstance3D = null
var _light: OmniLight3D = null
var _time: float = 0.0
var _base_dot_scale: Vector3 = Vector3.ONE


func _ready() -> void:
	_build_visuals()
	set_process(true)
	var quest := get_node_or_null("/root/QuestState")
	if quest != null and quest.has_signal("stage_changed"):
		quest.stage_changed.connect(_on_stage_changed)
		if stage_id.is_empty():
			_apply_visibility(not (hide_when_finished and quest.is_finished()), false)
		else:
			_apply_visibility(
				quest.get_current_stage_id() == stage_id
				and not (hide_when_finished and quest.is_finished()),
				false
			)
	else:
		_apply_visibility(true, false)


func _process(delta: float) -> void:
	if not _active:
		return
	_time += delta
	var pulse := 1.0 + sin(_time * pulse_speed) * pulse_amount
	if _dot != null:
		_dot.scale = _base_dot_scale * pulse
		var dot_material := _dot.material_override as StandardMaterial3D
		if dot_material != null:
			dot_material.emission_energy_multiplier = 2.2 * pulse
	if _ground != null:
		var ground_mat := _ground.material_override as StandardMaterial3D
		if ground_mat != null:
			ground_mat.albedo_color.a = 0.16 + 0.06 * (pulse - 1.0) / maxf(pulse_amount, 0.001)
	if _light != null:
		_light.light_energy = light_energy * pulse


# --- Публичный API ----------------------------------------------------------


func set_active(value: bool) -> void:
	_apply_visibility(value, true)


func is_active() -> bool:
	return _active


func set_stage_id(value: String) -> void:
	stage_id = value
	var quest := get_node_or_null("/root/QuestState")
	if quest != null:
		_on_stage_changed(quest.get_current_stage_id(), quest.get_current_stage_title())
	elif stage_id.is_empty():
		_apply_visibility(true, true)


func get_stage_id() -> String:
	return stage_id


func set_marker_color(value: Color) -> void:
	marker_color = value
	if _dot != null and _dot.material_override is StandardMaterial3D:
		(_dot.material_override as StandardMaterial3D).albedo_color = marker_color
	if _ground != null and _ground.material_override is StandardMaterial3D:
		var mat := _ground.material_override as StandardMaterial3D
		mat.albedo_color = Color(marker_color.r, marker_color.g, marker_color.b, 0.18)
	if _light != null:
		_light.light_color = marker_color


# --- Внутреннее -------------------------------------------------------------


func _build_visuals() -> void:
	# Пятно света на земле.
	_ground = MeshInstance3D.new()
	_ground.name = "GroundGlow"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = ground_radius
	cylinder.bottom_radius = ground_radius
	cylinder.height = 0.006
	cylinder.radial_segments = 24
	cylinder.rings = 1
	_ground.mesh = cylinder
	_ground.position = Vector3(0.0, 0.02, 0.0)
	_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ground_mat := StandardMaterial3D.new()
	ground_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ground_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ground_mat.albedo_color = Color(marker_color.r, marker_color.g, marker_color.b, 0.18)
	ground_mat.emission_enabled = true
	ground_mat.emission = marker_color
	ground_mat.emission_energy_multiplier = 0.35
	_ground.material_override = ground_mat
	add_child(_ground)

	# Маленькая пульсирующая точка — «цель здесь», без стрелки.
	_dot = MeshInstance3D.new()
	_dot.name = "Dot"
	var sphere := SphereMesh.new()
	sphere.radius = 0.055
	sphere.height = 0.11
	sphere.radial_segments = 12
	sphere.rings = 6
	_dot.mesh = sphere
	_dot.position = Vector3(0.0, dot_height, 0.0)
	_dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var dot_mat := StandardMaterial3D.new()
	dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot_mat.albedo_color = marker_color
	dot_mat.emission_enabled = true
	dot_mat.emission = marker_color
	dot_mat.emission_energy_multiplier = 2.2
	_dot.material_override = dot_mat
	add_child(_dot)
	_base_dot_scale = _dot.scale

	# Слабый свет, чтобы подсветить асфальт вокруг.
	_light = OmniLight3D.new()
	_light.name = "Glow"
	_light.position = Vector3(0.0, 0.7, 0.0)
	_light.light_color = marker_color
	_light.light_energy = light_energy
	_light.omni_range = maxf(ground_radius * 3.0, 1.2)
	_light.omni_attenuation = 1.6
	_light.shadow_enabled = false
	add_child(_light)


func _on_stage_changed(current_stage_id: String, _title: String) -> void:
	var quest := get_node_or_null("/root/QuestState")
	if hide_when_finished and quest != null and quest.is_finished():
		_apply_visibility(false, true)
		return
	if stage_id.is_empty():
		_apply_visibility(true, true)
		return
	_apply_visibility(current_stage_id == stage_id, true)


func _apply_visibility(value: bool, emit_signal: bool) -> void:
	if _active == value:
		if not value:
			visible = false
		return
	_active = value
	visible = value
	set_process(value)
	if emit_signal:
		if value:
			marker_shown.emit(stage_id)
		else:
			marker_hidden.emit(stage_id)
