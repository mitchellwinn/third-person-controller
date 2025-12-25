extends Control
class_name DialogueUI

## DialogueUI - UI component for displaying dialogue
## Dark panel with speaker, text, and horizontal choice buttons aligned right

signal next_pressed()
signal choice_pressed(index: int)

#region Node References
@onready var panel: PanelContainer = $Panel
@onready var speaker_label: Label = $Panel/VBox/SpeakerLabel
@onready var text_label: RichTextLabel = $Panel/VBox/TextLabel
@onready var bottom_row: HBoxContainer = $Panel/VBox/BottomRow
@onready var choices_container: HBoxContainer = $Panel/VBox/BottomRow/ChoicesContainer
@onready var next_indicator: Button = $Panel/VBox/BottomRow/NextIndicator
#endregion

#region Configuration
@export var show_next_indicator: bool = true
@export var next_indicator_text: String = "▼ Press Enter to continue"
#endregion

#region Style
var button_style_normal: StyleBoxFlat
var button_style_hover: StyleBoxFlat
var button_style_pressed: StyleBoxFlat
var button_style_disabled: StyleBoxFlat
#endregion

var choice_buttons: Array[Button] = []

func _ready():
	# Add to group so state_talking knows we need mouse visible
	add_to_group("ui_needs_mouse")
	
	# Initialize button styles
	_init_button_styles()
	
	# Hide choices initially
	if choices_container:
		choices_container.visible = false
	
	# Set up next/continue button
	if next_indicator:
		next_indicator.text = "Continue ▶"
		next_indicator.pressed.connect(_on_next_button_pressed)

func _init_button_styles():
	# Normal style
	button_style_normal = StyleBoxFlat.new()
	button_style_normal.bg_color = Color(0.12, 0.12, 0.16, 1)
	button_style_normal.border_color = Color(0.35, 0.35, 0.45, 1)
	button_style_normal.set_border_width_all(1)
	button_style_normal.set_corner_radius_all(3)
	button_style_normal.content_margin_left = 16
	button_style_normal.content_margin_right = 16
	button_style_normal.content_margin_top = 10
	button_style_normal.content_margin_bottom = 10
	
	# Hover style
	button_style_hover = StyleBoxFlat.new()
	button_style_hover.bg_color = Color(0.18, 0.18, 0.24, 1)
	button_style_hover.border_color = Color(0.5, 0.5, 0.65, 1)
	button_style_hover.set_border_width_all(1)
	button_style_hover.set_corner_radius_all(3)
	button_style_hover.content_margin_left = 16
	button_style_hover.content_margin_right = 16
	button_style_hover.content_margin_top = 10
	button_style_hover.content_margin_bottom = 10
	
	# Pressed style
	button_style_pressed = StyleBoxFlat.new()
	button_style_pressed.bg_color = Color(0.08, 0.08, 0.12, 1)
	button_style_pressed.border_color = Color(0.6, 0.6, 0.75, 1)
	button_style_pressed.set_border_width_all(1)
	button_style_pressed.set_corner_radius_all(3)
	button_style_pressed.content_margin_left = 16
	button_style_pressed.content_margin_right = 16
	button_style_pressed.content_margin_top = 10
	button_style_pressed.content_margin_bottom = 10
	
	# Disabled style
	button_style_disabled = StyleBoxFlat.new()
	button_style_disabled.bg_color = Color(0.08, 0.08, 0.1, 0.5)
	button_style_disabled.border_color = Color(0.2, 0.2, 0.25, 0.5)
	button_style_disabled.set_border_width_all(1)
	button_style_disabled.set_corner_radius_all(3)
	button_style_disabled.content_margin_left = 16
	button_style_disabled.content_margin_right = 16
	button_style_disabled.content_margin_top = 10
	button_style_disabled.content_margin_bottom = 10

func _input(event: InputEvent):
	if not visible:
		return
	
	# Enter/Space advances dialogue when no choices
	if event.is_action_pressed("ui_accept"):
		if choices_container.visible and choice_buttons.size() > 0:
			# If choices visible, select focused or first available
			var focused = get_viewport().gui_get_focus_owner()
			if focused in choice_buttons:
				focused.pressed.emit()
			else:
				_select_first_available_choice()
		else:
			next_pressed.emit()
		get_viewport().set_input_as_handled()
	
	# Number keys for quick choice selection (1-9)
	if choices_container.visible:
		for i in range(min(9, choice_buttons.size())):
			if event is InputEventKey and event.pressed and event.keycode == KEY_1 + i:
				_on_choice_pressed(i)
				get_viewport().set_input_as_handled()
				return

#region Public Methods
func set_speaker(speaker: String):
	if speaker_label:
		speaker_label.text = speaker
		speaker_label.visible = not speaker.is_empty()

func set_text(text: String):
	if text_label:
		text_label.text = text
	
	# Update next indicator visibility
	_update_next_indicator()

func set_choices(choices: Array):
	if not choices_container:
		return
	
	# Clear existing buttons
	_clear_choices()
	
	# Create choice buttons (right-aligned, horizontal)
	for i in range(choices.size()):
		var choice = choices[i]
		var button = _create_choice_button(choice, i)
		choices_container.add_child(button)
		choice_buttons.append(button)
	
	choices_container.visible = true
	_update_next_indicator()
	
	# Focus first available choice
	call_deferred("_focus_first_choice")

func hide_choices():
	if choices_container:
		choices_container.visible = false
		_clear_choices()
	
	_update_next_indicator()

func show_panel():
	if panel:
		panel.visible = true

func hide_panel():
	if panel:
		panel.visible = false

func enable_next_indicator():
	if next_indicator:
		next_indicator.text = "Continue ▶"
		_update_next_indicator()
#endregion

#region Internal Methods
func _create_choice_button(choice: Dictionary, index: int) -> Button:
	var button = Button.new()
	
	# Set text - short labels for horizontal layout
	var choice_text = choice.get("choice_text", choice.get("text", "..."))
	button.text = choice_text
	
	# Apply styles
	button.add_theme_stylebox_override("normal", button_style_normal)
	button.add_theme_stylebox_override("hover", button_style_hover)
	button.add_theme_stylebox_override("pressed", button_style_pressed)
	button.add_theme_stylebox_override("disabled", button_style_disabled)
	
	# Font settings
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	button.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	button.add_theme_color_override("font_pressed_color", Color(0.8, 0.8, 0.9))
	button.add_theme_color_override("font_disabled_color", Color(0.4, 0.4, 0.45))
	
	# Check availability
	var available = choice.get("available", true)
	if not available:
		button.disabled = true
		if choice.has("requirement_text"):
			button.tooltip_text = choice.requirement_text
	
	# Apply style variants
	var style = choice.get("style", "normal")
	match style:
		"positive":
			button.add_theme_color_override("font_color", Color(0.5, 0.85, 0.5))
			button.add_theme_color_override("font_hover_color", Color(0.6, 1.0, 0.6))
		"negative":
			button.add_theme_color_override("font_color", Color(0.85, 0.5, 0.5))
			button.add_theme_color_override("font_hover_color", Color(1.0, 0.6, 0.6))
		"special":
			button.add_theme_color_override("font_color", Color(0.85, 0.75, 0.4))
			button.add_theme_color_override("font_hover_color", Color(1.0, 0.9, 0.5))
	
	# Highlight default option with a brighter border
	if choice.get("is_default", false):
		var highlight_style = button_style_normal.duplicate()
		highlight_style.border_color = Color(0.6, 0.6, 0.8)
		highlight_style.border_width_bottom = 2
		button.add_theme_stylebox_override("normal", highlight_style)
	
	# Connect signal
	button.pressed.connect(_on_choice_pressed.bind(index))
	
	return button

func _clear_choices():
	for button in choice_buttons:
		button.queue_free()
	choice_buttons.clear()

func _focus_first_choice():
	for button in choice_buttons:
		if not button.disabled:
			button.grab_focus()
			return

func _select_first_available_choice():
	for i in range(choice_buttons.size()):
		if not choice_buttons[i].disabled:
			_on_choice_pressed(i)
			return

func _update_next_indicator():
	if not next_indicator:
		return
	
	# Hide next indicator when choices are visible
	if choices_container and choices_container.visible and choice_buttons.size() > 0:
		next_indicator.visible = false
	else:
		next_indicator.visible = show_next_indicator

func _on_choice_pressed(index: int):
	if index >= 0 and index < choice_buttons.size():
		if not choice_buttons[index].disabled:
			choice_pressed.emit(index)
			# Consume the input to prevent it from leaking through to game
			get_viewport().set_input_as_handled()

func _on_next_button_pressed():
	## Continue button was clicked
	next_pressed.emit()
	get_viewport().set_input_as_handled()

func _gui_input(event: InputEvent):
	# Consume all mouse clicks on the dialogue panel to prevent attack/interaction
	if event is InputEventMouseButton and event.pressed:
		get_viewport().set_input_as_handled()
#endregion
