extends EntityState
class_name StateAirborne

## Airborne state - handles all air movement including rising, falling, wall sliding, and wall jumping

enum Phase {RISING, FALLING}

@export_group("Physics")
@export var air_control: float = 0.3
@export var wall_slide_gravity_multiplier: float = 0.3
@export var wall_detection_distance: float = 0.6

@export_group("Momentum Conservation")
## How much of your launch momentum is preserved (1.0 = full conservation)
@export var momentum_conservation: float = 0.98
## Air control is divided by (1 + momentum_factor * this) - higher = harder to steer at high speeds
@export var momentum_control_penalty: float = 3.0
## Additional penalty when trying to steer AGAINST your momentum direction
@export var counter_momentum_penalty: float = 0.2
## Minimum speed (relative to base_move_speed) below which full air control is restored
@export var low_momentum_threshold: float = 0.5
## Air drag applied per second (very slight, mainly for feel)
@export var air_drag: float = 0.02

@export_group("Wall Jump")
@export var wall_jump_horizontal_force: float = 8.0
@export var wall_jump_vertical_force: float = 10.0
@export var wall_jump_cooldown: float = 0.15
@export var wall_jump_momentum_protection: float = 0.25 # Reduced air control after wall jump

@export_group("Debug")
@export var debug_airborne: bool = false # Set true to enable verbose airborne logging

var anim_controller: PlayerAnimationController = null
var current_phase: Phase = Phase.RISING
var time_in_state: float = 0.0

# Momentum conservation - stores horizontal velocity at time of becoming airborne
var launch_velocity: Vector3 = Vector3.ZERO

# Wall state (managed by this state, not entity)
var is_touching_wall: bool = false
var is_wall_sliding: bool = false
var wall_normal: Vector3 = Vector3.ZERO
var last_wall_jump_time: float = -999.0

func _ready():
	can_be_interrupted = false
	priority = 5
	allows_movement = true
	allows_rotation = true

func _find_anim_controller():
	if not anim_controller and entity:
		anim_controller = entity.get_node_or_null("AnimationController") as PlayerAnimationController
		if not anim_controller:
			anim_controller = entity.find_child("AnimationController", true, false) as PlayerAnimationController

func on_enter(previous_state = null):
	time_in_state = 0.0
	is_touching_wall = false
	is_wall_sliding = false
	wall_normal = Vector3.ZERO

	_find_anim_controller()

	# Store horizontal launch velocity for momentum conservation
	# This captures momentum from dash, sprint, ground movement, etc.
	if entity is CharacterBody3D:
		launch_velocity = Vector3(entity.velocity.x, 0, entity.velocity.z)

	# Determine initial phase based on velocity
	if entity is CharacterBody3D:
		if entity.velocity.y > 0:
			current_phase = Phase.RISING
			if anim_controller:
				anim_controller.set_jumping(true)
				anim_controller.set_falling(false)
		else:
			current_phase = Phase.FALLING
			if anim_controller:
				anim_controller.set_jumping(false)
				anim_controller.set_falling(true)

	if debug_airborne:
		var prev_name = previous_state.name if previous_state else "none"
		print("[StateAirborne] ENTER from %s, phase=%s, launch_vel=%.1f" % [prev_name, Phase.keys()[current_phase], launch_velocity.length()])

func on_physics_process(delta: float):
	time_in_state += delta

	# Remote players only update timers - no combat logic
	var is_remote = "_is_remote_player" in entity and entity._is_remote_player
	if is_remote:
		return

	if not entity is CharacterBody3D:
		complete()
		return

	var body = entity as CharacterBody3D

	# Update wall detection
	_update_wall_detection()

	# Apply gravity (reduced when wall sliding)
	var gravity = entity.gravity if "gravity" in entity else 20.0
	if is_wall_sliding:
		body.velocity.y -= gravity * wall_slide_gravity_multiplier * delta
	else:
		body.velocity.y -= gravity * delta

	# Check for phase transitions
	_update_phase()

	# Check for landing
	if body.is_on_floor() and time_in_state > 0.05:
		_land()
		return

	# Check for wall jump input
	# Server receives explicit wall_jump action with wall normal from client
	# Process ALL buffered wall jumps (client may send multiple per network tick)
	if state_manager:
		var wall_jump_result = state_manager.consume_buffered_input_with_data("wall_jump")
		while wall_jump_result.found:
			# Server: use client's wall normal (trust client's wall detection AND cooldown)
			var client_wall_normal = wall_jump_result.data.get("wall_normal", Vector3.ZERO)
			if client_wall_normal.length() > 0.1:
				wall_normal = client_wall_normal
				_perform_wall_jump_trusted(true) # Server replay - don't queue for sync!
			# Check for more buffered wall jumps
			wall_jump_result = state_manager.consume_buffered_input_with_data("wall_jump")
	
	# Local player: check input and wall detection
	if Input.is_action_just_pressed("jump") and is_touching_wall:
		_perform_wall_jump() # Has its own cooldown check
		return
	
	# Also check regular buffered jump for edge cases
	if state_manager and state_manager.consume_buffered_input("jump") and is_touching_wall:
		_perform_wall_jump() # Has its own cooldown check
		return
	
	# Check for air dash (Alt key, dodge input, or double-tap)
	var wants_dash = false
	var buffered_dir = Vector2(0, -1) # Default forward
	
	# Direct Alt key check for local player - capture direction NOW
	if "can_receive_input" in entity and entity.can_receive_input:
		if Input.is_action_just_pressed("dash") or Input.is_action_just_pressed("dodge"):
			wants_dash = true
			buffered_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
			if buffered_dir.length_squared() < 0.01:
				buffered_dir = Vector2(0, -1) # Default forward
	
	# Buffered input for server
	if state_manager:
		var dodge_result = state_manager.consume_buffered_input_with_data("dodge")
		if dodge_result.found:
			wants_dash = true
			buffered_dir = dodge_result.data.get("direction", Vector2(0, -1))
	
	# Double-tap detection
	if entity.has_method("try_dash") and entity.try_dash():
		wants_dash = true
		buffered_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		if buffered_dir.length_squared() < 0.01:
			buffered_dir = Vector2(0, -1)
	
	if wants_dash and state_manager.has_state("dash") and _has_stamina_for_dash():
		entity.set_meta("_buffered_dash_direction", buffered_dir)
		transition_to("dash")
		return
	
	# Check for air attack input -> AirSlash
	var wants_air_attack = false
	if "can_receive_input" in entity and entity.can_receive_input:
		if Input.is_action_just_pressed("fire") or Input.is_action_just_pressed("attack_primary"):
			wants_air_attack = true
	
	# Also check buffered attack input
	if state_manager and state_manager.consume_buffered_input("attack_primary"):
		wants_air_attack = true
	
	if wants_air_attack and state_manager.has_state("AirSlash"):
		transition_to("AirSlash")
		return

	# Air control
	_apply_air_control(delta)

	# Debug
	if debug_airborne and int(time_in_state * 4) != int((time_in_state - delta) * 4):
		print("[StateAirborne] phase=%s vel_y=%.2f wall_touch=%s wall_slide=%s" % [
			Phase.keys()[current_phase], body.velocity.y,
			str(is_touching_wall), str(is_wall_sliding)
		])

func _update_wall_detection():
	is_touching_wall = false
	is_wall_sliding = false
	wall_normal = Vector3.ZERO

	if not entity is CharacterBody3D:
		return

	var body = entity as CharacterBody3D

	# Don't detect walls on floor
	if body.is_on_floor():
		return

	var space_state = entity.get_world_3d().direct_space_state
	var ray_origin = entity.global_position + Vector3(0, 0.5, 0)
	var directions = [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]

	for dir in directions:
		var ray_end = ray_origin + dir * wall_detection_distance
		var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end, entity.collision_mask)
		query.exclude = [entity]

		var result = space_state.intersect_ray(query)
		if result:
			is_touching_wall = true
			wall_normal = result.normal
			break

	# Wall sliding only when falling and touching wall
	if is_touching_wall and current_phase == Phase.FALLING:
		is_wall_sliding = true

func _update_phase():
	if not entity is CharacterBody3D:
		return

	var body = entity as CharacterBody3D
	var new_phase = current_phase

	if body.velocity.y > 0.5:
		new_phase = Phase.RISING
	elif body.velocity.y < -0.5:
		new_phase = Phase.FALLING

	if new_phase != current_phase:
		current_phase = new_phase
		if debug_airborne:
			print("[StateAirborne] Phase changed to %s" % Phase.keys()[current_phase])

		# Update animation
		if anim_controller:
			if current_phase == Phase.RISING:
				anim_controller.set_jumping(true)
				anim_controller.set_falling(false)
			else:
				anim_controller.set_jumping(false)
				anim_controller.set_falling(true)

func _can_wall_jump() -> bool:
	var current_time = Time.get_ticks_msec() / 1000.0
	return current_time - last_wall_jump_time >= wall_jump_cooldown

func _perform_wall_jump():
	if not _can_wall_jump():
		return
	_perform_wall_jump_trusted()

func _perform_wall_jump_trusted(is_server_replay: bool = false):
	## Perform wall jump without cooldown check (for server trusting client)
	if not entity is CharacterBody3D:
		return

	var body = entity as CharacterBody3D

	# Jump direction: away from wall + up
	var jump_dir = (wall_normal + Vector3.UP).normalized()

	body.velocity.x = jump_dir.x * wall_jump_horizontal_force
	body.velocity.y = wall_jump_vertical_force
	body.velocity.z = jump_dir.z * wall_jump_horizontal_force
	
	# Update launch velocity for momentum conservation (wall jump gives new momentum)
	launch_velocity = Vector3(body.velocity.x, 0, body.velocity.z)

	last_wall_jump_time = Time.get_ticks_msec() / 1000.0
	current_phase = Phase.RISING

	if anim_controller:
		anim_controller.set_falling(false)
		anim_controller.set_jumping(true)
		# Restart jump animation from beginning for wall jumps
		anim_controller.restart_jump_animation()
	
	# Queue wall jump for network sync (LOCAL PLAYER ONLY - not server replay!)
	if not is_server_replay and entity.has_method("queue_wall_jump_for_sync"):
		# Only queue if this is the local player doing a new wall jump
		if "can_receive_input" in entity and entity.can_receive_input:
			entity.queue_wall_jump_for_sync(wall_normal)
	
	# Notify entity about wall jump for reconciliation grace (local player only)
	if not is_server_replay and entity.has_method("_on_wall_jump"):
		entity._on_wall_jump()

	if debug_airborne:
		print("[StateAirborne] WALL JUMP! dir=%s vel=%s normal=%s server=%s" % [str(jump_dir), str(body.velocity), str(wall_normal), str(is_server_replay)])

func _has_stamina_for_dash() -> bool:
	## Check if entity has enough stamina to dash
	if entity.has_method("has_stamina"):
		var dash_cost = entity.dash_stamina_cost if "dash_stamina_cost" in entity else 20.0
		return entity.has_stamina(dash_cost)
	return true # If no stamina system, allow dash

func _apply_air_control(delta: float):
	if not entity is CharacterBody3D:
		return

	var body = entity as CharacterBody3D
	var air_speed = entity.base_move_speed if "base_move_speed" in entity else 5.0
	
	# Get current horizontal velocity
	var current_h_vel = Vector3(body.velocity.x, 0, body.velocity.z)
	var current_speed = current_h_vel.length()
	
	# Apply very slight air drag (preserves most momentum)
	if current_speed > 0.1:
		var drag_factor = 1.0 - (air_drag * delta)
		body.velocity.x *= drag_factor
		body.velocity.z *= drag_factor
	
	# Get input direction
	var input_dir = Vector3.ZERO
	if entity.has_method("get_movement_input"):
		input_dir = entity.get_movement_input()

	if input_dir.length() < 0.1:
		return
	
	# Calculate momentum factor - how much faster than normal we're going
	var momentum_factor = clamp(current_speed / air_speed, 0.0, 3.0)
	
	# Base air control value
	var control = air_control
	
	# Reduce air control after wall jump to preserve wall jump momentum
	var current_time = Time.get_ticks_msec() / 1000.0
	var time_since_wall_jump = current_time - last_wall_jump_time
	if time_since_wall_jump < wall_jump_momentum_protection:
		control *= 0.1
	
	# If we have significant momentum, heavily reduce air control
	# This makes bunny hopping and dash jumping viable
	if momentum_factor > low_momentum_threshold:
		control /= (1.0 + momentum_factor * momentum_control_penalty)
		
		# Extra penalty when trying to steer AGAINST momentum direction
		if current_speed > 0.5:
			var current_dir = current_h_vel.normalized()
			var input_alignment = input_dir.dot(current_dir)
			if input_alignment < 0:
				# Trying to go opposite direction - very hard
				control *= counter_momentum_penalty
			elif input_alignment < 0.5:
				# Trying to turn sharply - somewhat hard
				control *= lerp(counter_momentum_penalty, 1.0, input_alignment * 2.0)
	
	# Apply air control as acceleration toward input direction
	# Rather than lerping directly to target, we add a small force
	var target_vel = input_dir * air_speed
	var vel_diff = target_vel - current_h_vel
	
	# Scale control by delta for frame-rate independence
	var influence = control * delta * 10.0
	
	body.velocity.x += vel_diff.x * influence
	body.velocity.z += vel_diff.z * influence

func _land():
	if anim_controller:
		anim_controller.play_land_animation()

	var input_dir = Vector3.ZERO
	if entity.has_method("get_movement_input"):
		input_dir = entity.get_movement_input()

	if debug_airborne:
		print("[StateAirborne] LANDED after %.2fs" % time_in_state)

	if input_dir.length() > 0.1:
		transition_to("moving", true)
	else:
		if entity.has_method("stop_movement"):
			entity.stop_movement()
		transition_to("idle", true)

func on_exit(next_state = null):
	if anim_controller:
		anim_controller.set_jumping(false)
		anim_controller.set_falling(false)

	if debug_airborne:
		var next_name = next_state.name if next_state else "none"
		print("[StateAirborne] EXIT to %s" % next_name)

func can_transition_to(state_name: String) -> bool:
	if state_name in ["stunned", "dead"]:
		return true
	if state_name.to_lower() in ["dodging", "dash", "airslash", "air_slash"]:
		return true
	return false
