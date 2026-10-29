extends Control
## Стартовая плашка «ГТА 6»: затемнение кадра, карточка с управлением и
## «Нажмите, чтобы начать».
##
## Пока плашка открыта: управление игроком выключено, мышь не захвачена,
## RayCast-интерактор выключен — движение, диалоги и квест не запускаются.
## Мягкий фонарь игрока (`PlayerFill`, группа "player_fill") тоже погашен, чтобы
## свет не проступал сквозь затемнение плашки, и включается после её закрытия.
## Клик или любая клавиша (Enter/Space/E/…) плавно убирает плашку, включает
## управление и захватывает мышь. Повторно в этом запуске не показывается.
##
## Группа: "title_card" — по ней плашку находят HUD и внешние системы.
##
## Публичный API:
##   dismiss()          — закрыть плашку кодом (как клик)
##   is_open() -> bool  — плашка ещё висит (до начала исчезновения)
##   is_dismissed() -> bool
## Сигнал: title_dismissed() — плашка полностью исчезла, управление включено.

signal title_dismissed()

const TITLE_TEXT := "ГТА 6"
const TITLE_GROUP := "title_card"
const PLAYER_FILL_GROUP := "player_fill"
const PLAYER_FILL_NAME := "PlayerFill"

## Длительность плавного исчезновения, сек.
@export var fade_duration: float = 0.55
## Блокировать игрока до старта (для тестов можно выключить).
@export var lock_player_until_start: bool = true

var _dismissed: bool = false
var _fading: bool = false
var _player: Player = null
var _interactor: Interactor = null

@onready var start_button: Button = $Center/Card/Margin/VBox/StartButton
@onready var title_label: Label = $Center/Card/Margin/VBox/TitleLabel


func _ready() -> void:
	add_to_group(TITLE_GROUP)
	visible = true
	modulate = Color(1, 1, 1, 1)
	_dismissed = false
	_fading = false
	start_button.pressed.connect(_dismiss)
	# Мягкий фонарь игрока не должен светить сквозь затемнение плашки —
	# гасим сразу и ещё раз отложенно, когда игрок точно в дереве.
	_apply_player_fill(false)
	call_deferred("_apply_player_fill", false)
	# Игрок и интерактор могут быть ещё не готовы в момент _ready — повторим
	# блокировку отложенно, к этому времени дерево сцены уже собрано.
	if lock_player_until_start:
		_apply_lock(true)
		call_deferred("_apply_lock", true)
	print("[title] стартовая плашка «%s» показана" % TITLE_TEXT)


## Плашка открыта и ещё не начала исчезать.
func is_open() -> bool:
	return visible and not _dismissed


func is_dismissed() -> bool:
	return _dismissed


# --- Ввод --------------------------------------------------------------------


func _input(event: InputEvent) -> void:
	if _dismissed or not visible:
		return
	# Любая нажатая клавиша (Enter, Space, E, Esc, ...) — начать игру.
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			_dismiss()
			get_viewport().set_input_as_handled()
		return
	# Клик в любом месте кадра (включая кнопку «НАЧАТЬ»).
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed:
			_dismiss()
			get_viewport().set_input_as_handled()


## Клик по затемнению или карточке (кнопка «НАЧАТЬ» обрабатывается отдельно).
func _gui_input(event: InputEvent) -> void:
	if _dismissed or not visible:
		return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed:
			_dismiss()
			accept_event()


# --- Закрытие и блокировка игрока -------------------------------------------


## Закрыть плашку: плавное исчезновение, затем включить управление.
func dismiss() -> void:
	_dismiss()


func _dismiss() -> void:
	if _dismissed or _fading:
		return
	_dismissed = true
	_fading = true
	start_button.disabled = true
	set_process_input(false)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "modulate:a", 0.0, maxf(fade_duration, 0.01))
	await tween.finished
	visible = false
	_fading = false
	_apply_lock(false)
	_apply_player_fill(true)
	title_dismissed.emit()
	print("[title] старт: плашка скрыта, управление включено (PlayerFill включён)")


## Мягкий фонарь игрока (группа "player_fill", узел PlayerFill) включается
## только после закрытия плашки. energy/range/цвет не трогаем — только visible.
func _apply_player_fill(enabled: bool) -> void:
	var fills := get_tree().get_nodes_in_group(PLAYER_FILL_GROUP)
	if fills.is_empty():
		# Запасной путь: узел по имени внутри игрока (если группа потерялась).
		var player := _player_node()
		if player != null:
			var found := player.find_child(PLAYER_FILL_NAME, true, false)
			if found != null:
				fills = [found]
	for node in fills:
		if node is Node3D:
			(node as Node3D).visible = enabled


func _player_node() -> Player:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Player
	return _player


func _apply_lock(locked: bool) -> void:
	if not lock_player_until_start:
		return
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Player
	if _player != null and _player.has_method("set_controls_enabled"):
		_player.set_controls_enabled(not locked)
	if _player != null and _player.has_method("set_mouse_captured"):
		# В headless мыши нет — не трогаем режим курсора, чтобы не шуметь в логах.
		if DisplayServer.get_name() != "headless":
			_player.set_mouse_captured(not locked)
	if _interactor == null or not is_instance_valid(_interactor):
		if _player != null and _player.has_method("get_interactor"):
			_interactor = _player.get_interactor()
	if _interactor != null and _interactor.has_method("set_interaction_enabled"):
		_interactor.set_interaction_enabled(not locked)
