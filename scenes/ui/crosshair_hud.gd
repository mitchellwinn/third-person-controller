extends Control
class_name CrosshairHUD

## Simple crosshair overlay that can change based on weapon state
## Also displays stamina bar at bottom center

#region Configuration
@export var crosshair_color: Color = Color(1, 1, 1, 0.8)
@export var crosshair_size: float = 20.0
@export var line_thickness: float = 2.0
@export var center_gap: float = 6.0  # Gap in center (no dot)
@export var hit_marker_duration: float = 0.15
@export var hit_marker_color: Color = Color(1, 0.3, 0.3, 1)

@export_group("Stamina Bar")
@export var stamina_bar_width: float = 200.0
@export var stamina_bar_height: float = 8.0
@export var stamina_bar_offset_y: float = 80.0  # Distance from bottom
@export var stamina_bar_bg_color: Color = Color(0.1, 0.1, 0.1, 0.6)
@export var stamina_bar_fill_color: Color = Color(0.2, 0.8, 0.4, 0.9)
@export var stamina_bar_low_color: Color = Color(0.9, 0.3, 0.2, 0.9)  # When low stamina
@export var stamina_low_threshold: float = 0.25  # Below 25% = low
#endregion

#region State
var _hit_marker_timer: float = 0.0
var _spread_current: float = 0.0
var _spread_target: float = 0.0
var _stamina_percent: float = 1.0
var _stamina_display: float = 1.0  # Smoothed display value
var _player_entity: Node = null
#endregion

func _ready():
	# Center the control
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Try to find local player after a short delay (for scene setup)
	await get_tree().create_timer(0.5).timeout
	_find_local_player()

func _find_local_player():
	## Find and connect to the local player entity
	var players = get_tree().get_nodes_in_group("players")
	for player in players:
		if player.has_method("can_receive_input") or "can_receive_input" in player:
			var can_input = player.can_receive_input if "can_receive_input" in player else true
			if can_input:
				_player_entity = player
				if _player_entity.has_signal("stamina_changed"):
					_player_entity.stamina_changed.connect(_on_stamina_changed)
				print("[CrosshairHUD] Connected to local player for stamina display")
				break

func _on_stamina_changed(current: float, maximum: float):
	_stamina_percent = current / maximum if maximum > 0 else 0.0

func _process(delta: float):
	# Update hit marker timer
	if _hit_marker_timer > 0:
		_hit_marker_timer -= delta
	
	# Smooth spread changes
	_spread_current = lerp(_spread_current, _spread_target, 15.0 * delta)
	
	# Smooth stamina bar animation
	_stamina_display = lerp(_stamina_display, _stamina_percent, 10.0 * delta)
	
	# Try to reconnect to player if lost
	if not is_instance_valid(_player_entity):
		_player_entity = null
		_find_local_player()
	
	# Redraw
	queue_redraw()

func _draw():
	var center = size / 2.0
	var color = hit_marker_color if _hit_marker_timer > 0 else crosshair_color
	
	# Calculate dynamic size based on spread
	var half_size = crosshair_size / 2.0 + _spread_current
	var gap = center_gap + _spread_current * 0.5
	
	# Draw four lines (cross pattern with gap in middle)
	# Top line
	draw_line(
		center + Vector2(0, -gap),
		center + Vector2(0, -half_size),
		color, line_thickness
	)
	# Bottom line
	draw_line(
		center + Vector2(0, gap),
		center + Vector2(0, half_size),
		color, line_thickness
	)
	# Left line
	draw_line(
		center + Vector2(-gap, 0),
		center + Vector2(-half_size, 0),
		color, line_thickness
	)
	# Right line
	draw_line(
		center + Vector2(gap, 0),
		center + Vector2(half_size, 0),
		color, line_thickness
	)
	
	# Optional: small center dot
	# draw_circle(center, 2.0, color)
	
	# Draw stamina bar at bottom center
	_draw_stamina_bar()

func show_hit_marker():
	## Flash the crosshair to indicate a hit
	_hit_marker_timer = hit_marker_duration

func set_spread(spread_degrees: float):
	## Set crosshair spread based on weapon accuracy
	# Convert degrees to pixels (rough approximation)
	_spread_target = spread_degrees * 3.0

func set_aiming(is_aiming: bool):
	## Tighten crosshair when aiming
	if is_aiming:
		crosshair_size = 14.0
		center_gap = 4.0
	else:
		crosshair_size = 20.0
		center_gap = 6.0

func _draw_stamina_bar():
	## Draw the stamina bar at bottom center of screen
	# Only draw if we have a player connected or if stamina is not full
	if _stamina_display >= 0.99 and not is_instance_valid(_player_entity):
		return  # Don't draw when full and no player (hidden until used)
	
	var bar_center_x = size.x / 2.0
	var bar_y = size.y - stamina_bar_offset_y
	
	# Background rect
	var bg_rect = Rect2(
		bar_center_x - stamina_bar_width / 2.0,
		bar_y - stamina_bar_height / 2.0,
		stamina_bar_width,
		stamina_bar_height
	)
	draw_rect(bg_rect, stamina_bar_bg_color)
	
	# Fill rect (stamina amount)
	var fill_width = stamina_bar_width * _stamina_display
	var fill_color = stamina_bar_low_color if _stamina_display < stamina_low_threshold else stamina_bar_fill_color
	
	# Smooth color transition near threshold
	if _stamina_display < stamina_low_threshold * 1.5 and _stamina_display >= stamina_low_threshold:
		var blend = (_stamina_display - stamina_low_threshold) / (stamina_low_threshold * 0.5)
		fill_color = stamina_bar_low_color.lerp(stamina_bar_fill_color, blend)
	
	var fill_rect = Rect2(
		bar_center_x - stamina_bar_width / 2.0,
		bar_y - stamina_bar_height / 2.0,
		fill_width,
		stamina_bar_height
	)
	draw_rect(fill_rect, fill_color)
	
	# Border
	draw_rect(bg_rect, Color(1, 1, 1, 0.3), false, 1.0)

func set_player(player: Node):
	## Manually set the player to track stamina from
	if _player_entity and _player_entity.has_signal("stamina_changed"):
		if _player_entity.stamina_changed.is_connected(_on_stamina_changed):
			_player_entity.stamina_changed.disconnect(_on_stamina_changed)
	
	_player_entity = player
	if _player_entity and _player_entity.has_signal("stamina_changed"):
		_player_entity.stamina_changed.connect(_on_stamina_changed)
		# Get initial stamina value
		if "current_stamina" in _player_entity and "max_stamina" in _player_entity:
			_stamina_percent = _player_entity.current_stamina / _player_entity.max_stamina
			_stamina_display = _stamina_percent

