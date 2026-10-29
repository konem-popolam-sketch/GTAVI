extends Area3D
## Точка входа в машину: игрок наводится на неё взглядом и жмёт E.
##
## Интерактор игрока (scripts/player/interactor.gd) поднимается по родителям и ищет
## узел с meta "interactable" = true или с методом interact(player). HUD сам рисует
## подсказку, если у цели есть get_interact_hint() (scripts/ui/hud.gd::_hint_for_target).

@export var hint: String = "E — сесть за руль"

var _car: Node3D = null


func _ready() -> void:
	add_to_group("vehicle_enter")
	set_meta("interactable", true)
	set_meta("interact_hint", hint)
	_car = get_parent() as Node3D
	monitoring = false
	monitorable = true


func get_interact_hint() -> String:
	return hint


func interact(player: Node3D = null) -> void:
	if _car == null:
		_car = get_parent() as Node3D
	if _car == null or player == null:
		return
	if _car.has_method("is_occupied") and bool(_car.call("is_occupied")):
		return
	if _car.has_method("enter"):
		_car.call("enter", player)
