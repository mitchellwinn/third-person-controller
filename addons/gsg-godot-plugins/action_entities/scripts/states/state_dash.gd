extends EntityState
class_name StateDash

## StateDash - Quick burst of speed in any direction
## Can be triggered by double-tap direction or Alt key
## Reduces downward velocity for air mobility
## Can cancel into AirSlash, which then allows another dash

@export_group("Dash Physics")
@export var dash_speed: float = 20.0 # Burst speed
@export var dash_duration: float = 0.25 # How long dash lasts
@export var vertical_damping: float = 0.3 # Reduces downward velocity (0 = full stop, 1 = no change)
@export var dash_cooldown: float = 0.1 # Minimum time between dashes

@export_group("Animation")
@export var forward_anim: String = "DashForward"
@export var forward_anim_alt: String = "DashForwardAlt"
@export var back_anim: String = "DashBack"
@export var back_anim_alt: String = "DashBackAlt"
@export var left_anim: String = "DashLeft"
@export var right_anim: String = "DashRight"
@export var fallback_anim: String = "dodge" # Use if specific anims not found
@export var anim_speed_scale: float = 0.4 # Slow down dash anims (default is too fast)

@export_group("Sound")
@export var dash_sound_path: String = "res://sounds/dash" # Base path (looks for dash_1.wav, dash_2.wav, etc.)
@export var dash_sound_volume: float = 0.0
@export var dash_sound_pitch_variation: float = 0.1

@export_group("Debug")
@export var debug_dash: bool = false # Set true to enable verbose dash logging

# Runtime
var dash_direction: Vector3 = Vector3.FORWARD
var dash_timer: float = 0.0
var can_cancel_to_air_slash: bool = true
var _initial_velocity: Vector3 = Vector3.ZERO
var _buffered_direction: Vector2 = Vector2.ZERO # Direction from buffered input

# Cooldown tracking (use entity metadata for persistence)
const DASH_COOLDOWN_KEY = "_last_dash_time"
const DASH_FOOT_KEY = "_dash_alt_foot" # Tracks which foot to use next (true = alt)

func _ready():
	can_be_interrupted = false
	priority = 8
	allows_movement = false
	allows_rotation = false

func on_enter(previous_state = null):
	dash_timer = 0.0
	can_cancel_to_air_slash = true
	_buffered_direction = Vector2.ZERO
	
	# Check stamina FIRST before doing anything else
	if entity.has_method("consume_stamina"):
		var dash_cost = entity.dash_stamina_cost if "dash_stamina_cost" in entity else 20.0
		if not entity.has_stamina(dash_cost):
			# Not enough stamina - immediately abort without any effects
			if debug_dash:
				print("[StateDash] Not enough stamina for dash! (need %.1f)" % dash_cost)
			# Use call_deferred to avoid state machine issues
			call_deferred("_abort_dash")
			return
		# Actually consume the stamina now that we know we have enough
		entity.consume_stamina(dash_cost)
	
	# Now we're committed to dashing - stop any playing animation
	_cancel_current_animation()
	
	# Store initial velocity for blending
	if entity is CharacterBody3D:
		_initial_velocity = entity.velocity
	
	# Check for buffered direction from entity metadata (set by idle/moving states)
	if entity.has_meta("_buffered_dash_direction"):
		_buffered_direction = entity.get_meta("_buffered_dash_direction")
		entity.remove_meta("_buffered_dash_direction") # Clear after reading
		if debug_dash:
			print("[StateDash] Using BUFFERED direction from meta: ", _buffered_direction)
	
	# Determine dash direction from buffered input, current input, or facing
	dash_direction = _get_dash_direction()
	
	# Apply initial dash velocity
	if entity is CharacterBody3D:
		var body = entity as CharacterBody3D
		body.velocity.x = dash_direction.x * dash_speed
		body.velocity.z = dash_direction.z * dash_speed
		
		# Reduce downward velocity (allows air dashing to slow fall)
		if body.velocity.y < 0:
			body.velocity.y *= vertical_damping
	
	# Record dash time for cooldown
	entity.set_meta(DASH_COOLDOWN_KEY, Time.get_ticks_msec() / 1000.0)
	
	# Play appropriate animation
	_play_dash_animation()
	
	# Play dash sound
	_play_dash_sound()
	
	if debug_dash:
		print("[StateDash] ENTER dir=%s speed=%.1f" % [dash_direction, dash_speed])

func _abort_dash():
	## Called when dash is aborted (not enough stamina, etc.)
	## Uses deferred call to safely transition back
	if state_manager:
		state_manager.change_state("Idle")

func on_physics_process(delta: float):
	dash_timer += delta

	# Remote players only update timers - no combat logic
	var is_remote = "_is_remote_player" in entity and entity._is_remote_player
	if is_remote:
		return

	# Check for attack cancel (can cancel anytime during dash)
	if can_cancel_to_air_slash and _check_attack_input():
		# IMPORTANT: Also consume the buffered input to prevent double-attack
		state_manager.consume_buffered_input("attack_primary")

		var is_airborne = not entity.is_on_floor() if entity is CharacterBody3D else false

		if is_airborne and state_manager.has_state("AirSlash"):
			# Air attack -> AirSlash
			transition_to("AirSlash")
			return
		else:
			# Ground attack -> first melee combo state
			var attack_state = _get_attack_state()
			if not attack_state.is_empty() and state_manager.has_state(attack_state):
				transition_to(attack_state)
				return
	
	# Check for dash cancel (another dash input)
	if _can_dash_again() and _check_dash_input():
		# Re-enter dash state with new direction
		transition_to("dash", true)
		return
	
	# Dash complete
	if dash_timer >= dash_duration:
		_finish_dash()
		return
	
	# Maintain dash velocity (resist deceleration)
	if entity is CharacterBody3D:
		var body = entity as CharacterBody3D
		var progress = dash_timer / dash_duration
		
		# Slight velocity decay toward end of dash
		var speed_mult = lerp(1.0, 0.5, progress)
		body.velocity.x = dash_direction.x * dash_speed * speed_mult
		body.velocity.z = dash_direction.z * dash_speed * speed_mult
		
		# Continue damping downward velocity
		if body.velocity.y < 0:
			body.velocity.y *= (1.0 - (1.0 - vertical_damping) * delta * 10)

func _get_dash_direction() -> Vector3:
	## Get dash direction from buffered input, current input, or entity facing
	var input_dir = Vector3.ZERO
	
	# PRIORITY 1: Use buffered direction if available (from when dash was pressed)
	if _buffered_direction.length_squared() > 0.01:
		# Convert 2D input to 3D world direction relative to camera/entity
		var camera = entity.get_viewport().get_camera_3d()
		if camera:
			var cam_basis = camera.global_transform.basis
			var forward = - cam_basis.z
			forward.y = 0
			forward = forward.normalized()
			var right = cam_basis.x
			right.y = 0
			right = right.normalized()
			input_dir = (right * _buffered_direction.x + forward * -_buffered_direction.y).normalized()
		else:
			# No camera, use entity basis
			input_dir = Vector3(_buffered_direction.x, 0, _buffered_direction.y)
		
		if debug_dash:
			print("[StateDash] Direction from buffer: 2D=", _buffered_direction, " -> 3D=", input_dir)
	else:
		# PRIORITY 2: Current input (for non-buffered dash)
		if entity.has_method("get_movement_input"):
			input_dir = entity.get_movement_input()
		elif "input_direction" in entity:
			input_dir = entity.input_direction
	
	# PRIORITY 3: If no input at all, dash forward (entity's facing direction)
	if input_dir.length() < 0.1:
		input_dir = - entity.global_transform.basis.z # Forward is -Z
		if debug_dash:
			print("[StateDash] No input direction, defaulting to forward: ", input_dir)
	
	input_dir.y = 0
	return input_dir.normalized()

func _play_dash_animation():
	if not entity.has_method("play_animation"):
		return
	
	# Determine animation based on dash direction relative to entity facing
	var entity_forward = - entity.global_transform.basis.z # -Z is forward
	var entity_right = entity.global_transform.basis.x # +X is right
	
	var forward_dot = dash_direction.dot(entity_forward)
	var right_dot = dash_direction.dot(entity_right)
	
	var anim_to_play = fallback_anim
	var is_forward_back = abs(forward_dot) > abs(right_dot)
	
	# Play animation matching the visual direction of movement
	if is_forward_back:
		# Get current foot state and toggle it BEFORE using (so first dash uses primary, second uses alt)
		var use_alt: bool = entity.get_meta(DASH_FOOT_KEY, false)
		
		if forward_dot < 0:
			# Dashing forward → Forward anim
			anim_to_play = forward_anim_alt if use_alt else forward_anim
			if debug_dash:
				print("[StateDash] Forward dash: using %s (alt=%s)" % ["FORWARD_ALT" if use_alt else "FORWARD", use_alt])
		else:
			# Dashing backward → Back anim
			anim_to_play = back_anim_alt if use_alt else back_anim
			if debug_dash:
				print("[StateDash] Backward dash: using %s (alt=%s)" % ["BACK_ALT" if use_alt else "BACK", use_alt])
		
		# Toggle for next dash
		entity.set_meta(DASH_FOOT_KEY, not use_alt)
		
		if debug_dash:
			print("[StateDash] Selected anim: '%s' (toggle for next: %s)" % [anim_to_play, not use_alt])
	else:
		# Side dashes - play animation matching movement direction
		if right_dot < 0:
			anim_to_play = right_anim # Dashing right → Right anim
		else:
			anim_to_play = left_anim # Dashing left → Left anim
	
	if debug_dash:
		print("[StateDash] Dash dir=%s, forward_dot=%.2f, right_dot=%.2f, anim=%s" % [dash_direction, forward_dot, right_dot, anim_to_play])
	
	entity.play_animation(anim_to_play, 0.0, true)
	
	# Set animation speed for dash (faster playback)
	var anim_controller = entity.get_node_or_null("AnimationController")
	if anim_controller and anim_controller.has_method("set_animation_speed"):
		anim_controller.set_animation_speed(anim_speed_scale)
	elif anim_controller and "animation_player" in anim_controller and anim_controller.animation_player:
		anim_controller.animation_player.speed_scale = anim_speed_scale

func _cancel_current_animation():
	## Stop any currently playing animation to prevent blending conflicts with dash
	var anim_controller = entity.get_node_or_null("AnimationController")
	if anim_controller and "animation_player" in anim_controller and anim_controller.animation_player:
		anim_controller.animation_player.stop()
		anim_controller.animation_player.clear_queue()
	elif entity.has_node("AnimationPlayer"):
		var anim_player = entity.get_node("AnimationPlayer")
		anim_player.stop()
		anim_player.clear_queue()

func _play_dash_sound():
	if dash_sound_path.is_empty():
		return
	
	var sound_manager = entity.get_node_or_null("/root/SoundManager")
	if not sound_manager:
		return
	
	# Play 3D sound at entity position with variation and random pitch
	if sound_manager.has_method("play_sound_3d_with_variation"):
		sound_manager.play_sound_3d_with_variation(
			dash_sound_path,
			entity.global_position,
			null,
			dash_sound_volume,
			dash_sound_pitch_variation
		)

func _check_attack_input() -> bool:
	if not entity or not "can_receive_input" in entity:
		return false
	
	if entity.can_receive_input:
		return Input.is_action_just_pressed("fire") or Input.is_action_just_pressed("attack_primary")
	else:
		# Server: check buffered input
		return state_manager.consume_buffered_input("attack_primary") if state_manager else false

func _check_dash_input() -> bool:
	if not entity or not "can_receive_input" in entity:
		return false
	
	if entity.can_receive_input:
		# Alt key or double-tap detected by entity - capture direction NOW
		if Input.is_action_just_pressed("dash") or Input.is_action_just_pressed("dodge"):
			var dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
			if dir.length_squared() < 0.01:
				dir = Vector2(0, -1) # Default forward
			entity.set_meta("_buffered_dash_direction", dir)
			return true
		return false
	else:
		# Server: check buffered input WITH direction data
		if state_manager:
			var result = state_manager.consume_buffered_input_with_data("dodge")
			if result.found:
				var dir = result.data.get("direction", Vector2(0, -1))
				entity.set_meta("_buffered_dash_direction", dir)
				return true
		return false

func _can_dash_again() -> bool:
	# Check cooldown
	var current_time = Time.get_ticks_msec() / 1000.0
	var last_time = entity.get_meta(DASH_COOLDOWN_KEY, -999.0)
	if current_time - last_time < dash_cooldown:
		return false
	
	# Check stamina
	if entity.has_method("has_stamina"):
		var dash_cost = entity.dash_stamina_cost if "dash_stamina_cost" in entity else 20.0
		if not entity.has_stamina(dash_cost):
			return false
	
	return true

func _get_attack_state() -> String:
	## Get the appropriate melee attack state based on equipped weapon
	var equip_manager = entity.get_node_or_null("EquipmentManager")
	if equip_manager and equip_manager.has_method("get_current_melee_component"):
		var melee = equip_manager.get_current_melee_component()
		if melee:
			# Check for combo controller's first state
			var combo_ctrl = entity.get_node_or_null("MeleeComboController")
			if combo_ctrl and "combo_states" in combo_ctrl and combo_ctrl.combo_states.size() > 0:
				return combo_ctrl.combo_states[0]
			# Fallback to generic state names
			if state_manager.has_state("saber_light_slash_0"):
				return "saber_light_slash_0"
	return ""

func can_dash_now() -> bool:
	## Check if dash is off cooldown for this entity
	var current_time = Time.get_ticks_msec() / 1000.0
	var last_time = entity.get_meta(DASH_COOLDOWN_KEY, -999.0)
	return current_time - last_time >= dash_cooldown

func _finish_dash():
	if debug_dash:
		print("[StateDash] FINISHED after %.2fs" % dash_timer)
	
	# Always transition to idle - let idle handle airborne detection
	# This keeps state flow clean: dash → idle → (idle detects air) → airborne
	transition_to("idle", true)

func on_exit(next_state = null):
	# Reset animation speed
	var anim_controller = entity.get_node_or_null("AnimationController")
	if anim_controller and "animation_player" in anim_controller and anim_controller.animation_player:
		anim_controller.animation_player.speed_scale = 1.0
	
	# Only apply slow blend for locomotion transitions (idle, moving, airborne)
	# Attack cancels (AirSlash, combo slashes) should snap immediately
	if next_state and entity.has_method("set_meta"):
		var next_name = next_state.name.to_lower() if next_state else ""
		var is_attack_cancel = "slash" in next_name or "attack" in next_name or "swing" in next_name
		if not is_attack_cancel:
			entity.set_meta("next_anim_blend_time", 0.4) # Slower blend out of dash
	
	if debug_dash:
		print("[StateDash] EXIT to %s" % (next_state.name if next_state else "none"))

func can_transition_to(state_name: String) -> bool:
	# Always allow these transitions
	var state_lower = state_name.to_lower()
	if state_lower in ["stunned", "dead", "airslash", "dash", "idle"]:
		return true
	# Allow melee attack states (combo states like "saber_light_slash_0")
	if "slash" in state_lower or "attack" in state_lower or "swing" in state_lower:
		return true
	return false
