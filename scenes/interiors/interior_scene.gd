extends Node3D
## Корневой скрипт интерьерной сцены (клуб / магазин).
##
## Зачем: интерьер можно запускать как отдельную сцену (для проверки и кадров)
## и инстансить внутрь main.tscn. В обоих режимах нужны разные вещи:
##   * отдельный запуск — своя Camera3D и своё окружение (туман/glow);
##   * внутри main — камеру и Environment отдаёт игра, иначе интерьерная
##     камера перехватит управление, а локальный fog перекроет ночную улицу.
##
## Скрипт определяет режим и гасит PreviewCamera/WorldEnvironment при инстансе.
## Свет-«качели» в клубе вращается здесь же (группа "interior_light_pivot"),
## чтобы не плодить AnimationPlayer и его ресурсы.

## Вращать свет-«качели» (узлы в группе "interior_light_pivot").
@export var animate_light_pivots: bool = true
## Скорость вращения, рад/с. У разных пивотов направление чередуется.
@export var pivot_speed: float = 0.55

var _clock: float = 0.0
var _pivots: Array[Node3D] = []
var _flicker_lights: Array[OmniLight3D] = []
var _flicker_base: Array[float] = []


func _ready() -> void:
	var standalone := _is_standalone()
	_apply_standalone_mode(standalone)
	for node in get_tree().get_nodes_in_group("interior_light_pivot"):
		if node is Node3D and is_ancestor_of(node):
			_pivots.append(node as Node3D)
	for node in get_tree().get_nodes_in_group("interior_flicker_light"):
		if node is OmniLight3D and is_ancestor_of(node):
			_flicker_lights.append(node as OmniLight3D)
			_flicker_base.append((node as OmniLight3D).light_energy)
	print("[interior] %s: режим %s, пивотов %d" % [
		name, "отдельная сцена" if standalone else "инстанс в игре", _pivots.size()
	])


func _process(delta: float) -> void:
	if not animate_light_pivots:
		return
	_clock += delta
	for i in _pivots.size():
		var pivot: Node3D = _pivots[i]
		if not is_instance_valid(pivot):
			continue
		var direction := 1.0 if i % 2 == 0 else -1.0
		pivot.rotation.y = _clock * pivot_speed * direction + float(i) * 1.4
	for i in _flicker_lights.size():
		var light: OmniLight3D = _flicker_lights[i]
		if not is_instance_valid(light):
			continue
		light.light_energy = _flicker_base[i] * (0.86 + 0.14 * sin(_clock * 5.0 + float(i) * 2.1))


## Отдельный запуск сцены: либо это current_scene, либо корень лежит прямо под
## SceneTree.root (запуск `godot res://...tscn`). Внутри main.tscn интерьер
## висит под Main/Interiors, поэтому оба условия ложны.
func _is_standalone() -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	if tree.current_scene == self:
		return true
	return get_parent() == tree.root


func _apply_standalone_mode(standalone: bool) -> void:
	var preview := get_node_or_null("PreviewCamera") as Camera3D
	if preview != null:
		preview.current = standalone
	var world_env := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_env != null and not standalone:
		# Внутри main.tscn действует общий ночной Environment; локальный туман
		# клуба включается интегратором только когда игрок внутри (см. docs).
		world_env.environment = null
