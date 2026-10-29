class_name Projectile
extends Node3D
## Projectile — короткоживущий визуальный трассер для хитскана.
##
## Это не баллистика: пуля в игре считается лучом (Weapon.fire()), а этот узел
## рисует отрезок от ствола до точки попадания на 0.08 с. Сцена:
## scenes/objects/projectile.tscn. Можно переиспользовать для других эффектов.
##
## API: launch(from: Vector3, to: Vector3, lifetime: float = 0.08)
## Сам удаляется по таймеру; никакой физики/коллизий не имеет.

@export var lifetime: float = 0.08
@export var color: Color = Color(1.0, 0.82, 0.42)

var _mesh: MeshInstance3D = null


func _ready() -> void:
	_mesh = get_node_or_null("Mesh") as MeshInstance3D
	set_process(false)


## Протянуть трассер от from до to и исчезнуть через lifetime секунд.
func launch(from: Vector3, to: Vector3, custom_lifetime: float = -1.0) -> void:
	var direction := to - from
	var length := direction.length()
	if length < 0.01:
		queue_free()
		return
	global_position = (from + to) * 0.5
	var up := Vector3.UP
	if absf(direction.normalized().dot(Vector3.UP)) > 0.99:
		up = Vector3.FORWARD
	look_at(to, up)
	if _mesh != null:
		_mesh.scale = Vector3(1.0, 1.0, length)
		_apply_color()
	var life := lifetime if custom_lifetime < 0.0 else custom_lifetime
	await get_tree().create_timer(maxf(life, 0.01)).timeout
	if is_inside_tree():
		queue_free()


func _apply_color() -> void:
	if _mesh == null:
		return
	var material := _mesh.material_override as StandardMaterial3D
	if material == null:
		return
	material.albedo_color = Color(color.r, color.g, color.b, 1.0)
	material.emission = color
