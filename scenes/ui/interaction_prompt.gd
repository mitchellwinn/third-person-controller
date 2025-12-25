extends Control
class_name InteractionPrompt

## Floating interaction prompt that appears near interactable objects
## Shows keybind and optional action text, positioned in screen-space
## near the world position of the target object.

#region Configuration
@export var key_text: String = "E"
@export var action_text: String = "Interact"
@export var offset_above_target: float = 2.2  # World units above target (for tall entities like NPCs)
@export var offset_above_pickup: float = 0.8  # World units above dropped items (closer to item)
@export var fade_in_speed: float = 8.0
@export var bob_amplitude: float = 3.0  # Pixels
@export var bob_speed: float = 2.5
#endregion

#region Node References
@onready var key_label: Label = $PanelContainer/HBox/KeyLabel
@onready var action_label: Label = $PanelContainer/HBox/ActionLabel
@onready var panel: PanelContainer = $PanelContainer
#endregion

#region State
var target_node: Node3D = null
var camera: Camera3D = null
var _alpha: float = 0.0
var _bob_time: float = 0.0
var _target_alpha: float = 1.0
#endregion

func _ready():
	# Start invisible
	modulate.a = 0.0
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if panel:
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(delta: float):
	if not visible or not target_node or not camera:
		return
	
	# Fade in/out
	_alpha = lerp(_alpha, _target_alpha, fade_in_speed * delta)
	modulate.a = _alpha
	
	# Subtle bobbing animation
	_bob_time += delta * bob_speed
	var bob_offset = sin(_bob_time) * bob_amplitude
	
	# Project world position to screen - check for custom offset first
	var offset = offset_above_target
	if target_node.is_in_group("dropped_items"):
		offset = offset_above_pickup
	elif "prompt_height_offset" in target_node:
		offset = target_node.prompt_height_offset
	var world_pos = target_node.global_position + Vector3.UP * offset
	
	# Check if behind camera
	var cam_forward = -camera.global_transform.basis.z
	var to_target = (world_pos - camera.global_position).normalized()
	if cam_forward.dot(to_target) < 0:
		modulate.a = 0.0
		return
	
	# Project to screen
	var screen_pos = camera.unproject_position(world_pos)
	
	# Clamp to screen bounds with padding
	var viewport_size = get_viewport().get_visible_rect().size
	var half_width = panel.size.x / 2.0 if panel else 60.0
	var half_height = panel.size.y / 2.0 if panel else 20.0
	
	screen_pos.x = clamp(screen_pos.x, half_width + 10, viewport_size.x - half_width - 10)
	screen_pos.y = clamp(screen_pos.y, half_height + 10, viewport_size.y - half_height - 10)
	
	# Apply position with bob
	position = screen_pos + Vector2(0, bob_offset) - panel.size / 2.0 if panel else screen_pos + Vector2(0, bob_offset)

func show_prompt(target: Node3D, cam: Camera3D, prompt_text: String = ""):
	## Show the interaction prompt for a target
	target_node = target
	camera = cam
	
	# Parse prompt text (format: "Press E to talk" -> key="E", action="Talk")
	if prompt_text.is_empty():
		action_label.text = action_text
	else:
		# Try to extract action from common formats
		var parsed = _parse_prompt_text(prompt_text)
		if action_label:
			action_label.text = parsed.action
		if key_label and not parsed.key.is_empty():
			key_label.text = parsed.key
	
	_target_alpha = 1.0
	_bob_time = 0.0
	visible = true

func hide_prompt():
	## Hide the interaction prompt with fade out
	_target_alpha = 0.0
	# Actually hide after fade completes
	var tween = create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.15)
	tween.tween_callback(func(): visible = false; target_node = null)

func _parse_prompt_text(text: String) -> Dictionary:
	## Parse common prompt formats like "Press E to talk" or "E - Interact"
	var result = {"key": key_text, "action": text}
	
	# Pattern: "Press X to Y"
	var press_regex = RegEx.new()
	press_regex.compile("(?i)press\\s+([A-Z0-9]+)\\s+to\\s+(.+)")
	var match_result = press_regex.search(text)
	if match_result:
		result.key = match_result.get_string(1).to_upper()
		result.action = match_result.get_string(2).capitalize()
		return result
	
	# Pattern: "X - Action" or "[X] Action"
	var bracket_regex = RegEx.new()
	bracket_regex.compile("\\[?([A-Z0-9]+)\\]?\\s*[-:]?\\s*(.+)")
	match_result = bracket_regex.search(text)
	if match_result:
		result.key = match_result.get_string(1).to_upper()
		result.action = match_result.get_string(2).capitalize()
		return result
	
	# Fallback: just use the text as action
	result.action = text.capitalize() if text.length() < 20 else "Interact"
	return result

func set_key(new_key: String):
	key_text = new_key
	if key_label:
		key_label.text = new_key

func set_action(new_action: String):
	action_text = new_action
	if action_label:
		action_label.text = new_action


