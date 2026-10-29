class_name ItemDropZone
extends Area3D
## ItemDropZone — место, куда можно положить несомый предмет (стойка прораба,
## ящик у пирса, багажник). Игрок наводится на зону и жмёт E: если в руках
## подходящий предмет, зона вызывает CarriedItem.drop_at().
##
## Сцена: scenes/objects/package_drop_zone.tscn. Узел — Area3D, поэтому не
## блокирует игрока; интерактор игрока видит Area3D (collide_with_areas = true)
## и находит метод interact().
##
## Публичный API:
##   can_accept(item) -> bool
##   interact(player)                  # вызывает Interactor по E
##   get_accepted_item_id() -> String
## Сигналы:
##   item_placed(item, zone)           # предмет успешно положен

signal item_placed(item: CarriedItem, zone: ItemDropZone)

@export var accepted_item_id: String = "package"
@export var display_name: String = "Стойка прораба"
## Смещение точки установки предмета относительно центра зоны (мировые оси).
@export var drop_offset: Vector3 = Vector3(0.0, 0.22, 0.0)
## Оставить ли предмет активным (false — скрыть после установки, например
## если прораб сразу забирает коробку).
@export var hide_item_after_drop: bool = false


func _ready() -> void:
	add_to_group("item_drop_zone")
	add_to_group("interactable")
	set_meta("interactable", true)
	set_meta("display_name", display_name)
	monitoring = false
	monitorable = true


func can_accept(item: CarriedItem) -> bool:
	if item == null or not is_instance_valid(item):
		return false
	if not item.is_carried():
		return false
	if accepted_item_id.is_empty():
		return true
	return item.get_item_id() == accepted_item_id


func get_accepted_item_id() -> String:
	return accepted_item_id


## Вызывается Interactor'ом по E рядом с зоной.
func interact(player: Node3D = null) -> void:
	var item := _find_carried_item(player)
	if item == null:
		return
	var target_position := global_position + drop_offset
	if not item.drop_at(target_position, self):
		return
	if hide_item_after_drop:
		item.visible = false
	item_placed.emit(item, self)


func _find_carried_item(player: Node3D = null) -> CarriedItem:
	for node in get_tree().get_nodes_in_group("carried_items"):
		var item := node as CarriedItem
		if item == null or not is_instance_valid(item):
			continue
		if not can_accept(item):
			continue
		if player != null and item.get_player() != null and item.get_player() != player:
			continue
		return item
	return null
