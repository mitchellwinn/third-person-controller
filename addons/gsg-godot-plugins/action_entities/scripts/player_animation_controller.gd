extends Node
class_name PlayerAnimationController

## Handles player animation blending based on movement state
## Supports idle, walk, and future strafe animations via BlendSpace2D

#region Configuration
@export var animation_tree: AnimationTree
@export var animation_player: AnimationPlayer

## Animation names (adjust to match your GLB's animation names)
@export_group("Animation Names")
@export var idle_anim: String = "idle"
@export var walk_anim: String = "walk"
@export var run_anim: String = "run" # Optional, falls back to walk
@export var jump_anim: String = "jump" # Jump takeoff animation
@export var fall_anim: String = "fall" # Falling animation (optional)
@export var land_anim: String = "land" # Landing animation (optional)
@export var strafe_left_anim: String = "" # Optional for future
@export var strafe_right_anim: String = "" # Optional for future
@export var walk_back_anim: String = "" # Optional for future

@export_group("Blend Settings")
@export var blend_speed: float = 10.0 # How fast to blend between animations
@export var movement_threshold: float = 0.1 # Min velocity to be considered "moving"
@export var min_anim_speed: float = 2.0 # Minimum animation speed when moving
@export var max_anim_speed: float = 6.0 # Maximum animation speed (for sprinting)
@export var use_velocity_scaling: bool = false # Scale anim speed with movement speed
#endregion

#region State
var entity: Node3D
var current_blend: float = 0.0 # 0 = idle, 1 = moving
var movement_blend_x: float = 0.0 # -1 = left, 0 = forward, 1 = right
var movement_blend_y: float = 0.0 # -1 = back, 0 = stop, 1 = forward
var is_sprinting: bool = false
var is_jumping: bool = false
var is_falling: bool = false

# For simple state machine approach (without full AnimationTree setup)
var use_simple_mode: bool = true

# Guard against double-snap race condition
var _last_snap_anim: String = ""
var _last_snap_frame: int = -1
var _last_snap_time: float = 0.0
const SNAP_GUARD_TIME: float = 0.05 # Minimum time between snaps of same animation (50ms)
#endregion

func _ready():
	entity = get_parent()
	
	# Try to find animation components if not assigned
	if not animation_tree:
		animation_tree = entity.get_node_or_null("AnimationTree")
	
	if not animation_player:
		# Search for AnimationPlayer in the model hierarchy
		animation_player = _find_animation_player(entity)
	
	# Determine mode based on what's available
	if animation_tree and animation_tree.tree_root:
		use_simple_mode = false
		_setup_animation_tree()
	elif animation_player:
		use_simple_mode = true
		var anims = animation_player.get_animation_list()
		print("[PlayerAnimationController] Found AnimationPlayer: ", animation_player.name)
		print("[PlayerAnimationController] Available animations: ", anims)
		
		# Try to play idle immediately
		if animation_player.has_animation(idle_anim):
			animation_player.play(idle_anim, -1, 1.0, false) # Loop
			print("[PlayerAnimationController] Playing idle: ", idle_anim)
		elif anims.size() > 0:
			# Try first available animation
			animation_player.play(anims[0], -1, 1.0, false) # Loop
			print("[PlayerAnimationController] Playing first anim: ", anims[0])
	else:
		push_warning("[PlayerAnimationController] No animation system found!")
		print("[PlayerAnimationController] Entity children: ", entity.get_children())
	
	# Print bone names for debugging
	print_bone_names()

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found = _find_animation_player(child)
		if found:
			return found
	return null

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found = _find_skeleton(child)
		if found:
			return found
	return null

func print_bone_names():
	## Call this to print all bone names in the skeleton
	var skeleton = _find_skeleton(entity)
	if skeleton:
		print("[PlayerAnimationController] Found Skeleton: ", skeleton.name)
		print("[PlayerAnimationController] Bone count: ", skeleton.get_bone_count())
		for i in skeleton.get_bone_count():
			var bone_name = skeleton.get_bone_name(i)
			var parent_idx = skeleton.get_bone_parent(i)
			var parent_name = skeleton.get_bone_name(parent_idx) if parent_idx >= 0 else "ROOT"
			print("  Bone %d: %s (parent: %s)" % [i, bone_name, parent_name])
	else:
		print("[PlayerAnimationController] No Skeleton3D found in entity hierarchy")

func _setup_animation_tree():
	## Configure AnimationTree if using advanced blending
	# This will be expanded when more animations are available
	print("[PlayerAnimationController] Using AnimationTree mode")

func _process(delta: float):
	if not entity:
		return
	
	# Check current state from entity's state manager
	var current_state_name = ""
	if entity.has_node("StateManager"):
		var state_mgr = entity.get_node("StateManager")
		if state_mgr.has_method("get_current_state_name"):
			current_state_name = state_mgr.get_current_state_name()
	
	# Skip locomotion animation updates if in an action state (attack, block, etc.)
	# Action states handle their own animations via play_action()
	if _is_action_state(current_state_name):
		return
	
	# Check if this is a remote player (no local input)
	var is_local_player = entity.get("can_receive_input") if "can_receive_input" in entity else true
	
	# Get movement state from entity
	var input_dir = Vector3.ZERO
	if entity.has_method("get_movement_input"):
		input_dir = entity.call("get_movement_input")
	elif "input_direction" in entity:
		input_dir = entity.input_direction
	
	# Calculate if moving based on input direction (works for both local and remote)
	var horizontal_input = Vector3(input_dir.x, 0, input_dir.z)
	var is_moving = horizontal_input.length() > movement_threshold
	
	# Check sprint state - try multiple methods
	is_sprinting = false
	# First check StateMoving's sprint state (most reliable)
	if current_state_name == "moving":
		var state_mgr = entity.get_node("StateManager")
		if "current_state" in state_mgr and state_mgr.current_state:
			if "is_sprinting" in state_mgr.current_state:
				is_sprinting = state_mgr.current_state.is_sprinting
	# Fallback to speed multiplier check
	if not is_sprinting and "current_speed_multiplier" in entity:
		is_sprinting = entity.current_speed_multiplier > 1.2
	# Last resort: check if entity has is_sprinting method
	if not is_sprinting and entity.has_method("is_sprinting"):
		is_sprinting = entity.call("is_sprinting")

	# Let states drive animation - jumping/airborne states set flags directly
	# For remote players, trust network state - don't use local physics checks
	if current_state_name in ["jumping", "airborne"]:
		# State is handling animation flags
		pass
	elif not is_local_player:
		# REMOTE PLAYER: Trust network state, not local physics
		# Animation flags are set by state changes from network sync
		# Don't use is_on_floor() or velocity - those aren't reliable for interpolated entities
		pass
	elif entity is CharacterBody3D:
		var body = entity as CharacterBody3D
		# LOCAL PLAYER: Velocity-based detection as fallback
		if not body.is_on_floor() and body.velocity.y > 0.5:
			if not is_jumping:
				set_jumping(true)
		elif not body.is_on_floor() and body.velocity.y < -0.5:
			if not is_falling:
				set_jumping(false)
				set_falling(true)
		elif body.is_on_floor() and (is_falling or is_jumping):
			set_jumping(false)
			set_falling(false)
	
	# Blend toward target (only if not jumping/falling)
	var target_blend = 1.0 if is_moving and not is_jumping and not is_falling else 0.0
	current_blend = lerp(current_blend, target_blend, blend_speed * delta)
	
	# Debug for remote players
	if not is_local_player and is_moving:
		if Engine.get_process_frames() % 60 == 0:
			print("[AnimController:Remote] Moving! input=%s blend=%.2f" % [input_dir, current_blend])
	
	# Calculate directional blend
	var raw_input = Vector2.ZERO
	
	if is_local_player:
		# Local player: use actual keyboard input for backwards detection
		if Input.is_action_pressed("move_forward"):
			raw_input.y += 1.0
		if Input.is_action_pressed("move_backward"):
			raw_input.y -= 1.0
		if Input.is_action_pressed("move_left"):
			raw_input.x -= 1.0
		if Input.is_action_pressed("move_right"):
			raw_input.x += 1.0
	else:
		# Remote player: derive direction from input_direction relative to entity facing
		if input_dir.length() > 0.1:
			var local_dir = entity.global_transform.basis.inverse() * input_dir.normalized()
			raw_input.x = local_dir.x
			raw_input.y = local_dir.z # +Z is forward in Godot
	
	if raw_input.length() > 0.1:
		raw_input = raw_input.normalized()
		movement_blend_x = lerp(movement_blend_x, raw_input.x, blend_speed * delta)
		movement_blend_y = lerp(movement_blend_y, raw_input.y, blend_speed * delta)
	else:
		movement_blend_x = lerp(movement_blend_x, 0.0, blend_speed * delta)
		movement_blend_y = lerp(movement_blend_y, 0.0, blend_speed * delta)
	
	# Set animation speed (but not for airborne animations - those always play at 1.0)
	if animation_player:
		if is_jumping or is_falling:
			# Jump/fall animations always play at normal speed
			animation_player.speed_scale = 1.0
		elif is_moving:
			var base_anim_speed: float
			if use_velocity_scaling:
				# Scale animation speed based on movement input
				var speed = horizontal_input.length()
				var base_speed = entity.base_move_speed if "base_move_speed" in entity else 5.0
				base_anim_speed = clampf(speed / base_speed, min_anim_speed, max_anim_speed)
			else:
				# Fixed animation speed based on walk/sprint
				base_anim_speed = max_anim_speed if is_sprinting else min_anim_speed
			
			# Reverse animation when walking backwards
			var is_walking_backwards = movement_blend_y < -0.3 # Threshold to avoid flicker
			if is_walking_backwards:
				animation_player.speed_scale = - base_anim_speed
			else:
				animation_player.speed_scale = base_anim_speed
		else:
			animation_player.speed_scale = 1.0
	
	# Apply animation
	if use_simple_mode:
		_update_simple_animation()
	else:
		_update_tree_animation()

func _find_animation_case_insensitive(anim_name: String) -> String:
	## Try to find animation with case-insensitive matching
	if not animation_player or anim_name.is_empty():
		return ""
	
	# First try exact match
	if animation_player.has_animation(anim_name):
		return anim_name
	
	# Try case-insensitive match
	var anim_list = animation_player.get_animation_list()
	for anim in anim_list:
		if anim.to_lower() == anim_name.to_lower():
			return anim
	
	return ""

func _update_simple_animation():
	## Simple mode: Just switch between idle, walk/run, and jump/fall
	if not animation_player:
		return

	# Find idle animation with case-insensitive matching
	var idle_anim_found = _find_animation_case_insensitive(idle_anim)
	var target_anim = idle_anim_found if idle_anim_found != "" else idle_anim
	var debug_reason = ""

	# Priority: Jump/Fall > Movement > Idle
	if is_jumping:
		var jump_anim_found = _find_animation_case_insensitive(jump_anim)
		if jump_anim_found != "":
			target_anim = jump_anim_found
			debug_reason = "jumping (found: " + jump_anim_found + ")"
		else:
			var fall_anim_found = _find_animation_case_insensitive(fall_anim)
			if fall_anim_found != "":
				target_anim = fall_anim_found
				debug_reason = "jumping (fallback: " + fall_anim_found + ")"
			else:
				debug_reason = "jumping (no anim found: " + jump_anim + ")"
				# Fall back to idle if jump animation not found
				target_anim = idle_anim_found if idle_anim_found != "" else idle_anim
	elif is_falling:
		var fall_anim_found = _find_animation_case_insensitive(fall_anim)
		if fall_anim_found != "":
			target_anim = fall_anim_found
			debug_reason = "falling"
		else:
			# Fallback to jump animation if no fall animation exists
			var jump_anim_found = _find_animation_case_insensitive(jump_anim)
			if jump_anim_found != "":
				target_anim = jump_anim_found
				debug_reason = "falling (using jump anim as fallback)"
			else:
				debug_reason = "falling (no anim found: " + fall_anim + ")"
	elif current_blend > 0.5:
		# Moving - use walk or run
		if is_sprinting and run_anim != "":
			var run_anim_found = _find_animation_case_insensitive(run_anim)
			if run_anim_found != "":
				target_anim = run_anim_found
				debug_reason = "running (sprint=" + str(is_sprinting) + ")"
			else:
				debug_reason = "running (no anim found: " + run_anim + ", sprint=" + str(is_sprinting) + ")"
		if target_anim == idle_anim_found or target_anim == idle_anim: # Didn't set run, try walk
			var walk_anim_found = _find_animation_case_insensitive(walk_anim)
			if walk_anim_found != "":
				target_anim = walk_anim_found
				debug_reason = "walking (sprint=" + str(is_sprinting) + ")"
			else:
				debug_reason = "walking (no anim found: " + walk_anim + ")"
	else:
		debug_reason = "idle (blend=" + str(current_blend) + ")"
	
	# Check if we should allow animation change
	var current_anim_name = animation_player.current_animation.to_lower()
	var current_is_airborne_anim = current_anim_name == jump_anim.to_lower() or current_anim_name == fall_anim.to_lower()
	var target_is_action = target_anim.to_lower() == jump_anim.to_lower() or target_anim.to_lower() == fall_anim.to_lower() or target_anim.to_lower() == land_anim.to_lower()
	var can_change = true
	
	# Check if grounded - if on floor, always allow transitioning away from jump/fall
	var is_grounded = false
	var is_local_player = entity.get("can_receive_input") if "can_receive_input" in entity else true
	if entity is CharacterBody3D:
		if is_local_player:
			is_grounded = (entity as CharacterBody3D).is_on_floor()
		else:
			# Remote player: trust state, not physics - assume grounded unless in airborne state
			var state_name = ""
			if entity.has_node("StateManager"):
				var sm = entity.get_node("StateManager")
				if sm.has_method("get_current_state_name"):
					state_name = sm.get_current_state_name()
			is_grounded = state_name not in ["airborne", "jumping"]
	
	if current_is_airborne_anim and not is_grounded:
		# Currently in the air with jump/fall animation
		if not target_is_action:
			# Trying to switch to locomotion while airborne - never allow
			can_change = false
			
			# If animation finished, freeze at the end frame (don't loop back to idle)
			if not animation_player.is_playing():
				var anim = animation_player.get_animation(animation_player.current_animation)
				if anim:
					# Seek to end and pause
					animation_player.seek(anim.length, true)
					animation_player.pause()
	# Note: Landing animation is NOT blocked - we always want to transition away from it
	
	# Only change if different and allowed
	if animation_player.current_animation != target_anim and can_change:
		if animation_player.has_animation(target_anim):
			# Jump/fall/land animations are one-shot (no loop), locomotion loops
			var is_airborne_or_land = target_anim.to_lower() == jump_anim.to_lower() or target_anim.to_lower() == fall_anim.to_lower() or target_anim.to_lower() == land_anim.to_lower()
			var should_loop = not is_airborne_or_land
			
			# Set loop mode on the animation resource
			var anim = animation_player.get_animation(target_anim)
			if anim:
				if should_loop:
					anim.loop_mode = Animation.LOOP_LINEAR
				else:
					anim.loop_mode = Animation.LOOP_NONE # Ensure jump/fall/land don't loop
			
			# Use shorter blend time for jump (more responsive)
			var blend_time = 0.1 if target_is_action else 0.2
			animation_player.play(target_anim, blend_time, 1.0, false) # Never pass loop flag - we set it on the resource
			# Debug output (throttled)
			if Engine.get_process_frames() % 60 == 0 or target_is_action: # Every second or immediately for jump/fall
				print("[PlayerAnimationController] Playing: ", target_anim, " (reason: ", debug_reason, ", loop=", should_loop, ")")
		else:
			# Animation not found - print available animations
			if Engine.get_process_frames() % 120 == 0: # Every 2 seconds
				var available = animation_player.get_animation_list()
				print("[PlayerAnimationController] Animation '", target_anim, "' not found! Available: ", available)
				print("[PlayerAnimationController] Looking for: idle=", idle_anim, " walk=", walk_anim, " run=", run_anim, " jump=", jump_anim)
	elif animation_player.current_animation == target_anim:
		# Animation is already playing - ensure loop mode is correct
		var is_airborne_or_land = target_anim.to_lower() == jump_anim.to_lower() or target_anim.to_lower() == fall_anim.to_lower() or target_anim.to_lower() == land_anim.to_lower()
		var anim = animation_player.get_animation(target_anim)
		if anim:
			if is_airborne_or_land:
				# Jump/fall/land should never loop
				if anim.loop_mode != Animation.LOOP_NONE:
					anim.loop_mode = Animation.LOOP_NONE
			else:
				# Locomotion should loop
				if anim.loop_mode != Animation.LOOP_LINEAR:
					anim.loop_mode = Animation.LOOP_LINEAR

func _update_tree_animation():
	## Advanced mode: Use AnimationTree for blending
	if not animation_tree:
		return
	
	# Set blend parameters
	# These parameter paths depend on how the AnimationTree is set up
	
	# For a simple state machine
	var state_machine = animation_tree.get("parameters/StateMachine/playback")
	if state_machine:
		var target_state = "idle"
		if current_blend > 0.5:
			target_state = "run" if is_sprinting else "walk"
		
		if state_machine.get_current_node() != target_state:
			state_machine.travel(target_state)
	
	# For BlendSpace2D (future strafe support)
	if animation_tree.has("parameters/MovementBlend/blend_position"):
		animation_tree.set("parameters/MovementBlend/blend_position", Vector2(movement_blend_x, movement_blend_y))
	
	# For simple idle/move blend
	if animation_tree.has("parameters/IdleMoveBlend/blend_amount"):
		animation_tree.set("parameters/IdleMoveBlend/blend_amount", current_blend)

#region Public API
func play_action(anim_name: String, blend_time: float = 0.2, snap: bool = false):
	## Play an animation with optional snap or blend
	## snap=true will instantly start from beginning (for attacks, dash)
	## snap=false uses blend_time for smooth transition (for locomotion)
	if not animation_player:
		push_warning("[PlayerAnimationController] No AnimationPlayer found for action: %s" % anim_name)
		return
	
	# Use case-insensitive matching
	var actual_anim = _find_animation_case_insensitive(anim_name)
	if actual_anim != "":
		if snap:
			var current_frame = Engine.get_process_frames()
			var current_time = Time.get_ticks_msec() / 1000.0

			# Guard against double-snap race condition
			# Skip if we already snapped to this same animation recently
			if _last_snap_anim == actual_anim:
				if _last_snap_frame == current_frame:
					print("[PlayerAnimationController] Skipping duplicate snap for: %s (same frame)" % actual_anim)
					return
				if current_time - _last_snap_time < SNAP_GUARD_TIME:
					print("[PlayerAnimationController] Skipping duplicate snap for: %s (within %.0fms)" % [actual_anim, SNAP_GUARD_TIME * 1000])
					return

			# For snapping: completely stop current animation and clear blend queue
			# This ensures no blending artifacts from previous animation
			animation_player.stop()
			animation_player.clear_queue()
			# CRITICAL: Reset speed_scale to positive before playing
			# Walking backwards sets speed_scale to negative, which would cause
			# action animations to be stuck at frame 0 (can't progress forward)
			animation_player.speed_scale = 1.0
			# Play with zero blend and immediately seek to start
			animation_player.play(actual_anim, 0.0, 1.0, false)
			animation_player.seek(0.0, true)

			# Record this snap to prevent race condition
			_last_snap_anim = actual_anim
			_last_snap_frame = current_frame
			_last_snap_time = current_time

			print("[PlayerAnimationController] Playing action: %s (SNAP)" % actual_anim)
		else:
			# Normal blend transition
			# Reset speed_scale in case it was negative from walking backwards
			animation_player.speed_scale = 1.0
			animation_player.play(actual_anim, blend_time, 1.0, false)
	else:
		# List available animations to help debug
		var available = animation_player.get_animation_list()
		push_warning("[PlayerAnimationController] Animation '%s' not found! Available: %s" % [anim_name, available])

func get_current_animation() -> String:
	if animation_player:
		return animation_player.current_animation
	return ""

func set_animation_speed(speed: float):
	## Set animation playback speed (useful for dash, etc.)
	if animation_player:
		animation_player.speed_scale = speed

func is_action_playing() -> bool:
	## Returns true if a non-locomotion animation is playing
	if not animation_player:
		return false
	var current = animation_player.current_animation
	return current != idle_anim and current != walk_anim and current != run_anim and current != jump_anim and current != fall_anim

func _is_action_state(state_name: String) -> bool:
	## Returns true if the state handles its own animation (attacks, blocks, etc.)
	## These states should not be interrupted by locomotion animation updates
	if state_name.is_empty():
		return false
	
	var state_lower = state_name.to_lower()
	
	# Attack states (combo system uses "saber_light_slash_X" pattern)
	if "slash" in state_lower or "attack" in state_lower:
		return true
	
	# Dash and air slash states
	if state_lower in ["dash", "airslash", "air_slash"]:
		return true
	
	# Block states
	if "block" in state_lower:
		return true
	
	# Stagger/stun states
	if state_lower in ["stunned", "stagger"]:
		return true
	
	# Dead state
	if state_lower == "dead":
		return true
	
	return false

func set_jumping(value: bool):
	## Call this when entering/exiting jump state
	if is_jumping != value:
		is_jumping = value
		if value:
			print("[PlayerAnimationController] Jump started")
		else:
			print("[PlayerAnimationController] Jump ended")
		if not value:
			is_falling = false

func restart_jump_animation():
	## Force restart the jump animation from the beginning (for wall jumps)
	if animation_player and jump_anim != "":
		var actual_anim = _find_animation_case_insensitive(jump_anim)
		if actual_anim != "":
			# Seek to beginning and play with tiny blend for snappy restart
			animation_player.play(actual_anim, 0.02, 1.0, false)
			animation_player.seek(0.0, true) # Force to beginning
			print("[PlayerAnimationController] Jump animation restarted (wall jump)")

func set_falling(value: bool):
	## Call this when falling (negative Y velocity)
	is_falling = value
	if value:
		is_jumping = false

func play_land_animation():
	## Play landing animation if available
	if animation_player and land_anim != "" and animation_player.has_animation(land_anim):
		animation_player.play(land_anim, 0.1, 1.0, false) # Quick blend, no loop
	is_jumping = false
	is_falling = false

#endregion
