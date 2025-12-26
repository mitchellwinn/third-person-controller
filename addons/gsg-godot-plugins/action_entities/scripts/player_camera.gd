extends Node3D
class_name PlayerCamera

## Third-person over-shoulder camera with:
## - Shoulder swap (X key)
## - No wall collision (smooth fade/push)
## - Squad spectating on death

#region Signals
signal shoulder_swapped(is_right: bool)
signal spectate_target_changed(target: Node3D)
signal aim_changed(is_aiming: bool)
#endregion

#region Configuration
@export_group("Follow")
@export var follow_target: Node3D
@export var follow_speed: float = 10.0
@export var rotation_speed: float = 10.0

@export_group("Offset")
@export var camera_distance: float = 3.5
@export var camera_height: float = 1.8
@export var shoulder_offset: float = 1.5  # How far to the side
@export var shoulder_swap_speed: float = 8.0

@export_group("Look")
@export var mouse_sensitivity: float = 0.002
@export var min_pitch: float = -80.0
@export var max_pitch: float = 80.0
@export var invert_y: bool = false

@export_group("Collision")
@export var collision_margin: float = 0.2
@export var collision_smooth_speed: float = 15.0
@export var min_distance: float = 0.5

@export_group("Look Ahead")
@export var look_ahead_distance: float = 10.0  # How far ahead of the player to look
@export var look_ahead_height: float = 0.0  # Vertical offset for look ahead point

@export_group("Aiming")
@export var aim_distance: float = 2.0  # Camera distance when aiming
@export var aim_fov: float = 50.0  # FOV when aiming
@export var aim_shoulder_offset: float = 1.0  # Tighter shoulder offset when aiming
@export var aim_transition_speed: float = 10.0
@export var aim_look_ahead_distance: float = 15.0  # Look further ahead when aiming

@export_group("Input")
@export var shoulder_swap_action: String = "shoulder_swap"
@export var spectate_next_action: String = "spectate_next"
@export var spectate_prev_action: String = "spectate_prev"
#endregion

#region State
var camera: Camera3D
var spring_arm: Node3D  # Virtual spring arm (we handle collision ourselves)

# Look angles
var yaw: float = 0.0
var pitch: float = 0.0

# Shoulder
var is_right_shoulder: bool = true
var current_shoulder_offset: float = 1.5

# Collision
var current_distance: float = 3.5
var target_distance: float = 3.5
var _aim_distance_current: float = 3.5  # Current camera distance (before collision)

# Spectating
var is_spectating: bool = false
var spectate_targets: Array[Node3D] = []
var spectate_index: int = 0
var original_target: Node3D = null

# Aiming
var is_aiming: bool = false
var default_fov: float = 70.0
var default_distance: float = 3.5
var default_shoulder_offset: float = 1.5

# Advanced Recoil System
@export var recoil_recovery_speed: float = 12.0  # How fast recoil recovers
@export var recoil_overshoot: float = 1.2  # How much we overshoot when recovering (creates bounce)
@export var screen_shake_intensity: float = 0.8  # Screen shake multiplier
@export var screen_shake_decay: float = 8.0  # How fast screen shake fades

var _recoil_pitch: float = 0.0  # Current recoil offset
var _recoil_yaw: float = 0.0
var _recoil_velocity_pitch: float = 0.0  # Velocity for spring physics
var _recoil_velocity_yaw: float = 0.0

# Screen shake (separate from recoil)
var _screen_shake_pitch: float = 0.0
var _screen_shake_yaw: float = 0.0
var _screen_shake_intensity: float = 0.0  # Current shake intensity

# Recoil accumulation (builds up with rapid fire)
var _recoil_accumulation: float = 0.0
var _recoil_accumulation_decay: float = 4.0
#endregion

func _ready():
	# Create camera if not already child
	camera = get_node_or_null("Camera3D")
	if not camera:
		camera = Camera3D.new()
		camera.name = "Camera3D"
		add_child(camera)

	# Extend far clipping plane for large environments
	camera.far = 8000.0
	
	# Capture mouse
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	# Register input actions if needed
	_ensure_input_actions()
	
	# Initialize distance
	current_distance = camera_distance
	target_distance = camera_distance
	_aim_distance_current = camera_distance
	current_shoulder_offset = shoulder_offset if is_right_shoulder else -shoulder_offset
	
	# Store defaults for aim transitions
	default_fov = camera.fov
	default_distance = camera_distance
	default_shoulder_offset = shoulder_offset

func _ensure_input_actions():
	if not InputMap.has_action(shoulder_swap_action):
		InputMap.add_action(shoulder_swap_action)
		var event = InputEventKey.new()
		event.keycode = KEY_X
		InputMap.action_add_event(shoulder_swap_action, event)
	
	if not InputMap.has_action(spectate_next_action):
		InputMap.add_action(spectate_next_action)
		var event = InputEventKey.new()
		event.keycode = KEY_E
		InputMap.action_add_event(spectate_next_action, event)
	
	if not InputMap.has_action(spectate_prev_action):
		InputMap.add_action(spectate_prev_action)
		var event = InputEventKey.new()
		event.keycode = KEY_Q
		InputMap.action_add_event(spectate_prev_action, event)

func _unhandled_input(event: InputEvent):
	# Skip input if window doesn't have focus (prevents input bleeding between test windows)
	if not DisplayServer.window_is_focused():
		return

	# Mouse look
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		var pitch_delta = event.relative.y * mouse_sensitivity
		if invert_y:
			pitch_delta = -pitch_delta
		pitch = clamp(pitch - pitch_delta, deg_to_rad(min_pitch), deg_to_rad(max_pitch))
	
	# Shoulder swap
	if event.is_action_pressed(shoulder_swap_action):
		swap_shoulder()
	
	# Spectating controls
	if is_spectating:
		if event.is_action_pressed(spectate_next_action):
			spectate_next()
		elif event.is_action_pressed(spectate_prev_action):
			spectate_previous()

func _physics_process(delta: float):
	if not follow_target:
		return
	
	# Update recoil spring system
	_update_recoil(delta)
	
	# Determine target values based on aiming state
	var effective_shoulder_offset = aim_shoulder_offset if is_aiming else default_shoulder_offset
	var effective_camera_distance = aim_distance if is_aiming else default_distance
	var effective_fov = aim_fov if is_aiming else default_fov
	
	# Smooth shoulder offset transition (considering aiming)
	var target_shoulder = effective_shoulder_offset if is_right_shoulder else -effective_shoulder_offset
	current_shoulder_offset = lerp(current_shoulder_offset, target_shoulder, shoulder_swap_speed * delta)
	
	# Smooth FOV transition
	camera.fov = lerp(camera.fov, effective_fov, aim_transition_speed * delta)
	
	# Smooth camera distance for aiming (don't modify the export, use tracking variable)
	_aim_distance_current = lerp(_aim_distance_current, effective_camera_distance, aim_transition_speed * delta)
	
	# Calculate ideal camera position
	var target_pos = follow_target.global_position + Vector3(0, camera_height, 0)
	
	# Build rotation from yaw/pitch (including smoothed recoil)
	var effective_pitch = pitch + _recoil_pitch
	var effective_yaw = yaw + _recoil_yaw
	var rotation_basis = Basis.from_euler(Vector3(effective_pitch, effective_yaw, 0))
	
	# Calculate offset position (behind and to the side)
	var offset = rotation_basis * Vector3(current_shoulder_offset, 0, _aim_distance_current)
	var ideal_position = target_pos + offset
	
	# Check for collision
	target_distance = _calculate_safe_distance(target_pos, rotation_basis)
	current_distance = lerp(current_distance, target_distance, collision_smooth_speed * delta)
	
	# Apply clamped distance
	var final_offset = rotation_basis * Vector3(current_shoulder_offset, 0, current_distance)
	var final_position = target_pos + final_offset
	
	# Smooth follow
	global_position = global_position.lerp(final_position, follow_speed * delta)
	
	# Look ahead of the player, not at them
	# Use the full rotation (yaw AND pitch) to calculate forward direction
	var forward_dir = -rotation_basis.z  # Forward is -Z in Godot
	
	# Use different look ahead distance when aiming
	var effective_look_ahead = aim_look_ahead_distance if is_aiming else look_ahead_distance
	
	# Look target is ahead of the player in the camera's facing direction (including vertical angle)
	var look_target = target_pos + forward_dir * effective_look_ahead + Vector3(0, look_ahead_height, 0)
	camera.look_at(look_target)

func _update_recoil(delta: float):
	## Advanced recoil system with spring physics, screen shake, and accumulation

	# Spring physics for recoil recovery with overshoot
	var spring_force = recoil_recovery_speed * recoil_recovery_speed
	var damping = 2.0 * sqrt(spring_force) * 0.8  # Critical damping with slight under-damping for feel

	# Calculate forces
	var pitch_force = -_recoil_pitch * spring_force - _recoil_velocity_pitch * damping
	var yaw_force = -_recoil_yaw * spring_force - _recoil_velocity_yaw * damping

	# Apply forces
	_recoil_velocity_pitch += pitch_force * delta
	_recoil_velocity_yaw += yaw_force * delta

	# Update positions
	_recoil_pitch += _recoil_velocity_pitch * delta
	_recoil_yaw += _recoil_velocity_yaw * delta

	# Screen shake decay (separate from camera recoil)
	_screen_shake_intensity = maxf(0, _screen_shake_intensity - screen_shake_decay * delta)
	var shake_factor = _screen_shake_intensity * screen_shake_intensity

	# Add procedural shake to current recoil
	if _screen_shake_intensity > 0.01:
		var shake_time = Time.get_ticks_msec() * 0.01
		var shake_pitch = sin(shake_time * 23.7) * shake_factor * 0.5
		var shake_yaw = cos(shake_time * 31.3) * shake_factor * 0.3
		_recoil_pitch += shake_pitch
		_recoil_yaw += shake_yaw

	# Decay accumulation (recoil gets easier to control as you stop firing)
	_recoil_accumulation = maxf(0, _recoil_accumulation - _recoil_accumulation_decay * delta)

func _calculate_safe_distance(origin: Vector3, rotation_basis: Basis) -> float:
	var space_state = get_world_3d().direct_space_state
	
	# Cast ray from target to ideal camera position
	var direction = rotation_basis * Vector3(current_shoulder_offset, 0, _aim_distance_current).normalized()
	var end_pos = origin + direction * _aim_distance_current
	
	var query = PhysicsRayQueryParameters3D.create(origin, end_pos)
	query.collision_mask = 1  # Environment layer
	if follow_target:
		query.exclude = [follow_target.get_rid()]
	
	var result = space_state.intersect_ray(query)
	
	if result:
		var hit_distance = origin.distance_to(result.position) - collision_margin
		return max(hit_distance, min_distance)
	
	return _aim_distance_current

#region Shoulder Swap
func swap_shoulder():
	is_right_shoulder = not is_right_shoulder
	shoulder_swapped.emit(is_right_shoulder)

func set_shoulder(right: bool):
	if is_right_shoulder != right:
		is_right_shoulder = right
		shoulder_swapped.emit(is_right_shoulder)
#endregion

#region Spectating
func start_spectating(targets: Array[Node3D]):
	if targets.is_empty():
		return
	
	original_target = follow_target
	spectate_targets = targets
	spectate_index = 0
	is_spectating = true
	
	_set_spectate_target(spectate_targets[0])

func stop_spectating():
	if not is_spectating:
		return
	
	is_spectating = false
	spectate_targets.clear()
	
	if original_target:
		follow_target = original_target
		spectate_target_changed.emit(original_target)
	
	original_target = null

func spectate_next():
	if spectate_targets.is_empty():
		return
	
	spectate_index = (spectate_index + 1) % spectate_targets.size()
	_set_spectate_target(spectate_targets[spectate_index])

func spectate_previous():
	if spectate_targets.is_empty():
		return
	
	spectate_index = (spectate_index - 1 + spectate_targets.size()) % spectate_targets.size()
	_set_spectate_target(spectate_targets[spectate_index])

func _set_spectate_target(target: Node3D):
	# Remove dead targets
	if not is_instance_valid(target):
		spectate_targets.erase(target)
		if spectate_targets.is_empty():
			stop_spectating()
			return
		spectate_index = spectate_index % spectate_targets.size()
		target = spectate_targets[spectate_index]
	
	follow_target = target
	spectate_target_changed.emit(target)

func get_spectate_target() -> Node3D:
	return follow_target if is_spectating else null

func update_spectate_targets(targets: Array[Node3D]):
	## Call this when squad members change (death, disconnect)
	spectate_targets = targets
	
	# If current target is gone, switch to next valid
	if is_spectating and follow_target not in spectate_targets:
		if spectate_targets.is_empty():
			stop_spectating()
		else:
			spectate_index = 0
			_set_spectate_target(spectate_targets[0])
#endregion

#region Public API
func set_target(target: Node3D):
	follow_target = target
	if not is_spectating:
		original_target = target

func get_camera() -> Camera3D:
	return camera

func get_pitch() -> float:
	## Returns camera pitch in radians (negative = looking up)
	return pitch

func get_yaw() -> float:
	## Returns camera yaw in radians
	return yaw

func get_aim_direction() -> Vector3:
	## Returns the direction the camera is looking (for aiming)
	return -camera.global_transform.basis.z

func get_aim_origin() -> Vector3:
	## Returns camera position for raycasting aim
	return camera.global_position

func set_mouse_captured(captured: bool):
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE

func is_mouse_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

func set_aiming(aiming: bool):
	## Enable/disable aim mode (closer camera, narrower FOV)
	if is_aiming != aiming:
		is_aiming = aiming
		aim_changed.emit(is_aiming)

func get_is_aiming() -> bool:
	return is_aiming

func set_aim_zoom(zoom: float):
	## Set custom aim zoom level (overrides default)
	aim_fov = default_fov / zoom

func apply_recoil(vertical: float, horizontal: float, weapon_type: String = "rifle"):
	## Apply advanced recoil with accumulation and screen shake

	# Base kick values (scaled by accumulation)
	var base_pitch_kick = deg_to_rad(vertical)
	var base_yaw_kick = deg_to_rad(horizontal)

	# Accumulation makes recoil worse with rapid fire
	var accumulation_factor = 1.0 + (_recoil_accumulation * 0.3)
	_recoil_accumulation += 0.1  # Build up accumulation

	# Apply accumulation to pitch more than yaw (vertical kick builds up more)
	var pitch_kick = base_pitch_kick * accumulation_factor
	var yaw_kick = base_yaw_kick * (1.0 + _recoil_accumulation * 0.1)

	# Random variation for feel
	var pitch_variation = randf_range(0.8, 1.2)
	var yaw_variation = randf_range(-1.0, 1.0) * 0.3  # Less variation in yaw

	pitch_kick *= pitch_variation
	yaw_kick *= (1.0 + yaw_variation)

	# Weapon-specific modifiers
	match weapon_type.to_lower():
		"pistol":
			pitch_kick *= 0.8  # Pistols have snappier recoil
			yaw_kick *= 1.2
		"shotgun":
			pitch_kick *= 1.5  # Shotguns have heavy vertical kick
			yaw_kick *= 0.5
		"sniper":
			pitch_kick *= 0.6  # Snipers are more controlled
			yaw_kick *= 0.4
		_:  # rifle (default)
			pass

	# Add immediate kick to current position (sharp feel)
	_recoil_pitch += pitch_kick * 0.7  # 70% immediate
	_recoil_yaw += yaw_kick * 0.7

	# Add the rest as velocity for spring recovery
	_recoil_velocity_pitch += pitch_kick * 0.3
	_recoil_velocity_yaw += yaw_kick * 0.3

	# Screen shake (visual feedback separate from aim)
	_screen_shake_intensity = minf(1.0, _screen_shake_intensity + 0.3)

	# Clamp to prevent extreme values
	_recoil_pitch = clampf(_recoil_pitch, deg_to_rad(-30), deg_to_rad(45))
	_recoil_yaw = clampf(_recoil_yaw, deg_to_rad(-25), deg_to_rad(25))
	_recoil_velocity_pitch = clampf(_recoil_velocity_pitch, deg_to_rad(-50), deg_to_rad(50))
	_recoil_velocity_yaw = clampf(_recoil_velocity_yaw, deg_to_rad(-30), deg_to_rad(30))
#endregion

