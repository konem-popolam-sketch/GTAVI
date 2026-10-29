class_name NightGate
extends Node3D
## Шлагбаум парковки — визуальная реакция мира на сюжетные флаги.
##
## Интеграция (t21): узел стоит в `scenes/main.tscn` в группе `night_gate`;
## `QuestDirector` находит его по группе и вызывает `set_gate_closed(closed)`:
## закрыт, пока идёт ночная смена (`night_started`), открыт после `ending_shift`.
##
## Стрела намеренно БЕЗ коллизии: закрытый шлагбаум не должен отрезать
## парковку — туда ведёт стадия `find_foreman`, и софтлок был бы обидным.
## Геометрия строится кодом, внешних ассетов не требует.
##
## Публичный API:
##   set_gate_closed(closed: bool) -> void
##   is_gate_closed() -> bool
##   set_gate_closed_immediate(closed: bool) -> void   # без анимации (тесты)

const ARM_LENGTH := 5.0
const ARM_HEIGHT := 1.15
const OPEN_ANGLE := -1.42

var _arm: Node3D = null
var _closed := false
var _tween: Tween = null


func _ready() -> void:
	add_to_group("night_gate")
	_build()
	_apply_state(_closed, false)


## Закрыть (true) или открыть (false) шлагбаум с плавной анимацией.
func set_gate_closed(closed: bool) -> void:
	_apply_state(closed, true)


## Мгновенно, без анимации — удобно для тестов и загрузки сцены.
func set_gate_closed_immediate(closed: bool) -> void:
	_apply_state(closed, false)


func is_gate_closed() -> bool:
	return _closed


# --- Внутреннее --------------------------------------------------------------

func _apply_state(closed: bool, animate: bool) -> void:
	_closed = closed
	var target: float = 0.0 if closed else OPEN_ANGLE
	if _arm == null:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if not animate or not is_inside_tree():
		_arm.rotation.x = target
		return
	_tween = create_tween()
	_tween.tween_property(_arm, "rotation:x", target, 1.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _build() -> void:
	if _arm != null:
		return
	_arm = Node3D.new()
	_arm.name = "Arm"
	add_child(_arm)

	var red := _make_material(Color(0.62, 0.12, 0.1), 0.55)
	var white := _make_material(Color(0.86, 0.84, 0.78), 0.6)
	var steel := _make_material(Color(0.32, 0.33, 0.35), 0.45)

	# Стрела: красная труба по +Z от стойки до конца проёма.
	_add_box(_arm, "Boom", Vector3(0.1, 0.12, ARM_LENGTH), Vector3(0.0, ARM_HEIGHT, ARM_LENGTH * 0.5), red)
	# Белые полосы — «шлагбаумная» разметка.
	for i in 3:
		var z: float = 0.75 + float(i) * 1.5
		_add_box(_arm, "Stripe%d" % (i + 1), Vector3(0.12, 0.13, 0.34), Vector3(0.0, ARM_HEIGHT, z), white)
	# Противовес за стойкой и шарнир.
	_add_box(_arm, "Counterweight", Vector3(0.16, 0.3, 0.7), Vector3(0.0, ARM_HEIGHT - 0.12, -0.45), steel)
	_add_box(_arm, "Pivot", Vector3(0.2, 0.26, 0.2), Vector3(0.0, ARM_HEIGHT, 0.04), steel)
	# Фонарь на стреле — в темноте видно, что проезд закрыт.
	var lamp := OmniLight3D.new()
	lamp.name = "Lamp"
	lamp.position = Vector3(0.0, ARM_HEIGHT + 0.22, ARM_LENGTH * 0.62)
	lamp.light_color = Color(1.0, 0.32, 0.22)
	lamp.light_energy = 0.7
	lamp.omni_range = 4.5
	lamp.shadow_enabled = false
	_arm.add_child(lamp)


func _add_box(parent: Node3D, node_name: String, size: Vector3, pos: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = pos
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	return instance


func _make_material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = 0.15
	return material
