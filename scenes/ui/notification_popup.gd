extends Control
class_name NotificationPopup

## NotificationPopup - Displays notification messages with an OK button or auto-dismiss
## Can be used for errors, info, or confirmations

signal dismissed()
signal confirmed()

#region Node References
@onready var panel: PanelContainer = $Panel
@onready var message_label: Label = $Panel/VBox/MessageLabel
@onready var ok_button: Button = $Panel/VBox/OKButton
#endregion

#region Configuration
@export var auto_dismiss_time: float = 0.0  # 0 = require button click
@export var default_message: String = ""
#endregion

#region State
var _dismiss_timer: float = 0.0
#endregion

func _ready():
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	
	# Add to group so state_talking knows we need mouse visible
	add_to_group("ui_needs_mouse")
	
	if ok_button:
		ok_button.pressed.connect(_on_ok_pressed)
	
	if default_message:
		show_message(default_message)

func _process(delta: float):
	if visible and auto_dismiss_time > 0:
		_dismiss_timer -= delta
		if _dismiss_timer <= 0:
			dismiss()

func _gui_input(event: InputEvent):
	# Consume all input on this popup
	if event is InputEventMouseButton:
		get_viewport().set_input_as_handled()

func _input(event: InputEvent):
	if not visible:
		return
	
	# Allow Enter/Space to dismiss
	if event.is_action_pressed("ui_accept"):
		_on_ok_pressed()
		get_viewport().set_input_as_handled()

#region Public API
func show_message(text: String, dismiss_time: float = 0.0):
	## Show a notification message
	## dismiss_time: 0 = require OK button, >0 = auto dismiss after N seconds
	if message_label:
		message_label.text = text
	
	auto_dismiss_time = dismiss_time
	_dismiss_timer = dismiss_time
	
	# Show/hide OK button based on auto-dismiss
	if ok_button:
		ok_button.visible = (dismiss_time <= 0)
	
	visible = true
	# Enter talking state (single source of truth for mouse visibility)
	_ensure_talking_state()

func dismiss():
	visible = false
	dismissed.emit()
	# Exit talking state - it will check if other UIs still need mouse
	_exit_talking_state()

func show_error(text: String):
	## Show an error notification (always requires OK)
	show_message(text, 0.0)

func show_info(text: String, duration: float = 3.0):
	## Show an info notification (auto-dismisses)
	show_message(text, duration)
#endregion

#region Callbacks
func _on_ok_pressed():
	visible = false
	confirmed.emit()
	dismissed.emit()
	_exit_talking_state()
#endregion

#region Mouse State Helpers
func _ensure_talking_state():
	## Enter talking state to show mouse cursor
	var player = _get_local_player()
	if not player:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	
	var state_manager = player.get_node_or_null("StateManager")
	if not state_manager:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	
	if state_manager.has_method("get_current_state_name"):
		if state_manager.get_current_state_name() == "talking":
			return
	
	if state_manager.has_method("change_state") and state_manager.has_method("has_state"):
		if state_manager.has_state("talking"):
			state_manager.change_state("talking", true)
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _exit_talking_state():
	## Exit talking state - it will check if other UIs still need mouse
	var player = _get_local_player()
	if not player:
		return
	
	var state_manager = player.get_node_or_null("StateManager")
	if not state_manager:
		return
	
	if state_manager.has_method("get_current_state_name"):
		if state_manager.get_current_state_name() != "talking":
			return
	
	if state_manager.has_method("change_state") and state_manager.has_method("has_state"):
		if state_manager.has_state("idle"):
			state_manager.change_state("idle", true)

func _get_local_player() -> Node:
	var players = get_tree().get_nodes_in_group("players")
	for player in players:
		if "can_receive_input" in player and player.can_receive_input:
			return player
	return null
#endregion


