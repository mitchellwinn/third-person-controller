extends Node

## NotificationManager - Global singleton for displaying notifications
## Accessed via autoload: NotificationManager.show_notification("message")
## Add to autoload as "NotificationManager"

#region State
var _popup_scene: PackedScene = null
var _canvas_layer: CanvasLayer = null
var _current_popup: Control = null
var _queue: Array[Dictionary] = []
#endregion

func _ready():
	# Load popup scene
	_popup_scene = load("res://scenes/ui/notification_popup.tscn")
	
	# Create canvas layer for popups (very high layer)
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.layer = 150
	add_child(_canvas_layer)

#region Public API
func show_notification(message: String, auto_dismiss: float = 0.0):
	## Show a notification popup
	## auto_dismiss: 0 = require OK click, >0 = auto dismiss after N seconds
	if _current_popup and _current_popup.visible:
		# Queue it
		_queue.append({"message": message, "auto_dismiss": auto_dismiss})
		return
	
	_show_popup(message, auto_dismiss)

func show_error(message: String):
	## Show an error that requires acknowledgment
	show_notification(message, 0.0)

func show_info(message: String, duration: float = 3.0):
	## Show an info notification that auto-dismisses
	show_notification(message, duration)

func show_toast(message: String, duration: float = 2.0):
	## Show a quick toast message at the top of the screen
	_show_toast(message, duration)
#endregion

#region Internal
func _show_popup(message: String, auto_dismiss: float):
	if not _popup_scene:
		push_error("[NotificationManager] Popup scene not loaded")
		return
	
	_current_popup = _popup_scene.instantiate()
	_canvas_layer.add_child(_current_popup)
	
	_current_popup.dismissed.connect(_on_popup_dismissed)
	_current_popup.show_message(message, auto_dismiss)

func _on_popup_dismissed():
	if _current_popup:
		_current_popup.queue_free()
		_current_popup = null
	
	# Show next in queue
	if _queue.size() > 0:
		var next = _queue.pop_front()
		call_deferred("_show_popup", next.message, next.auto_dismiss)

func _show_toast(message: String, duration: float):
	# Create a simple toast label at the top
	var toast = Label.new()
	toast.text = message
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.add_theme_color_override("font_color", Color.WHITE)
	toast.add_theme_font_size_override("font_size", 18)
	
	# Position at top center
	toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast.position.y = 50
	
	# Add background panel
	var bg = PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_CENTER_TOP)
	bg.add_child(toast)
	bg.position.y = 40
	bg.modulate = Color(1, 1, 1, 0)  # Start invisible
	
	_canvas_layer.add_child(bg)
	
	# Animate in and out
	var tween = create_tween()
	tween.tween_property(bg, "modulate:a", 1.0, 0.2)
	tween.tween_interval(duration)
	tween.tween_property(bg, "modulate:a", 0.0, 0.3)
	tween.tween_callback(bg.queue_free)
#endregion

