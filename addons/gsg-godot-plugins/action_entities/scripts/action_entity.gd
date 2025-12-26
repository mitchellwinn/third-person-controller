extends CharacterBody3D
class_name ActionEntity

## ActionEntity - Base class for all 3D action game entities
## Supports skeletal mesh, state machine, combat, and networking

signal entity_spawned()
signal entity_despawned()
signal stamina_changed(current: float, maximum: float)

#region Configuration
@export_group("Entity Info")
@export var entity_id: String = ""
@export var display_name: String = ""
@export var team_id: int = 0

@export_group("Movement")
@export var base_move_speed: float = 3.5
@export var sprint_multiplier: float = 1.6
@export var acceleration: float = 15.0
@export var deceleration: float = 12.0
@export var rotation_speed: float = 10.0
@export var gravity: float = 28.0

@export_group("Momentum")
@export var sprint_turn_penalty: float = 0.4
@export var sharp_turn_angle: float = 60.0
@export var momentum_recovery_speed: float = 3.0

@export_group("Stamina")
@export var max_stamina: float = 100.0
@export var stamina_regen_rate: float = 30.0  # Per second when not draining
@export var stamina_regen_delay: float = 0.5  # Seconds after using stamina before regen starts
@export var sprint_stamina_drain: float = 6.0  # Per second while sprinting
@export var dash_stamina_cost: float = 12.0  # Per dash

@export_group("Visual")
@export var mesh_root: Node3D
@export var animation_tree: AnimationTree
@export var skeleton: Skeleton3D
@export var enable_blob_shadow: bool = true ## Add blob shadow under entity
@export var shadow_base_size: float = 1.0 ## Base size of blob shadow
#endregion

#region Component References
var state_manager
var combat
var network_identity
var ragdoll_controller: DynamicRagdollController
#endregion

#region Runtime State
var move_direction: Vector3 = Vector3.ZERO
var face_direction: Vector3 = Vector3.FORWARD
var current_speed_multiplier: float = 1.0
var is_invulnerable: bool = false

var _last_move_direction: Vector3 = Vector3.ZERO
var _momentum_multiplier: float = 1.0

# Knockback system - smooth decay over time
var knockback_velocity: Vector3 = Vector3.ZERO
var knockback_decay_rate: float = 25.0  # How fast knockback decays (higher = faster falloff) - dramatic falloff
var knockback_min_threshold: float = 1.0  # Stop applying when below this

# Hitlag freeze state
var _is_hitlag_frozen: bool = false

# Stamina state
var current_stamina: float = 100.0
var _stamina_regen_timer: float = 0.0  # Time since last stamina use
var _is_stamina_draining: bool = false  # True while actively draining (sprint, etc.)

static var entity_registry: Dictionary = {}
#endregion

#region Server Entity Networking
## All server-controlled entities (enemies, NPCs, etc.) use this for sync
@export_group("Server Entity")
@export var is_server_entity: bool = false  # Set true for server-controlled entities
@export var server_sync_rate: float = 10.0  # How often to broadcast state (Hz)

var _network_id: int = -1  # Unique ID for network identification
var _server_sync_timer: float = 0.0

func get_network_id() -> int:
	## Returns unique network ID for this entity (server assigns, clients receive)
	if _network_id < 0:
		_network_id = get_instance_id()  # Server uses instance ID
	return _network_id

func set_network_id(id: int):
	## Called by clients when receiving server's network ID
	_network_id = id

func is_server() -> bool:
	## Check if we're running on the server
	var network = get_node_or_null("/root/NetworkManager")
	return not network or network.is_server

func get_server_entity_state() -> Dictionary:
	## Override in subclasses to add more state. Base state for all server entities.
	# Only sync Y rotation - X/Z should always be 0 (entities stay upright)
	return {
		"network_id": get_network_id(),
		"position": global_position,
		"rotation": Vector3(0, global_rotation.y, 0),  # Only Y rotation (facing direction)
		"velocity": velocity,
		"health": combat.current_health if combat else 100.0,
		"max_health": combat.max_health if combat else 100.0,
		"is_dead": is_dead(),
	}

func apply_server_entity_state(state: Dictionary):
	## Apply state received from server. Override in subclasses for more state.
	# Store server's network ID so client uses same ID for hit validation
	if state.has("network_id") and _network_id < 0:
		_network_id = state.get("network_id")
	
	# Don't override position during knockback/hitstun - let physics play out
	if is_hitstunned() or knockback_velocity.length_squared() > 0.001:
		pass  # Skip position update - let local knockback/hitstun play out
	else:
		global_position = state.get("position", global_position)
		global_rotation = state.get("rotation", global_rotation)

func broadcast_server_entity_state():
	## Server broadcasts state to clients in the same zone
	if not is_server() or not is_server_entity:
		return

	var state = get_server_entity_state()

	# Get zone-filtered peer list
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("get_entity_zone_id"):
		var zone_id = network.get_entity_zone_id(self)
		if not zone_id.is_empty():
			# Only send to peers in the same zone
			var peers = network.get_peers_in_zone(zone_id)
			for peer_id in peers:
				if peer_id != 1:  # Don't send to server
					_rpc_receive_server_entity_state.rpc_id(peer_id, state)
			return

	# Fallback: broadcast to all (legacy behavior)
	_rpc_receive_server_entity_state.rpc(state)

@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_receive_server_entity_state(state: Dictionary):
	## Client receives state from server
	if is_server():
		return
	apply_server_entity_state(state)
#endregion

func _ready():
	add_to_group("action_entities")
	_find_components()

	if entity_id != "":
		entity_registry[entity_id] = self

	if combat:
		combat.died.connect(_on_died)
		combat.damage_taken.connect(_on_damage_taken)

	# Server entities get added to group for network queries
	if is_server_entity:
		add_to_group("server_entities")

	# Add blob shadow if enabled
	if enable_blob_shadow:
		_setup_blob_shadow()

	entity_spawned.emit()


func _setup_blob_shadow():
	## Add a blob shadow under the entity
	var ShadowScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/entity_shadow.gd")
	if ShadowScript:
		var shadow = ShadowScript.new()
		shadow.name = "BlobShadow"
		shadow.base_size = shadow_base_size
		add_child(shadow)

func _find_components():
	for child in get_children():
		var script = child.get_script()
		if script:
			var script_path = script.resource_path
			if "entity_state_manager" in script_path:
				state_manager = child
			elif "combat_component" in script_path:
				combat = child
			elif "network_identity" in script_path:
				network_identity = child
			elif "dynamic_ragdoll_controller" in script_path:
				ragdoll_controller = child

	if not state_manager:
		var StateManagerScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/states/entity_state_manager.gd")
		state_manager = StateManagerScript.new()
		state_manager.name = "StateManager"
		add_child(state_manager)

	var has_states = false
	for child in state_manager.get_children():
		if child.get_script() and "state_" in child.get_script().resource_path:
			has_states = true
			break

	if not has_states:
		print("[ActionEntity] Adding default states to empty StateManager")
		_add_default_states()
		if state_manager.has_method("_discover_states"):
			state_manager._discover_states(state_manager)
		if state_manager.has_method("_enter_default_state"):
			state_manager.call_deferred("_enter_default_state")

func _add_default_states():
	var StateIdleScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/states/state_idle.gd")
	var idle = StateIdleScript.new()
	idle.name = "Idle"
	state_manager.add_child(idle)

	var StateMovingScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/states/state_moving.gd")
	var moving = StateMovingScript.new()
	moving.name = "Moving"
	state_manager.add_child(moving)

	var StateJumpingScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/states/state_jumping.gd")
	var jumping = StateJumpingScript.new()
	jumping.name = "Jumping"
	state_manager.add_child(jumping)

	var StateAirborneScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/states/state_airborne.gd")
	var airborne = StateAirborneScript.new()
	airborne.name = "Airborne"
	state_manager.add_child(airborne)

	var StateDodgingScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/states/state_dodging.gd")
	var dodging = StateDodgingScript.new()
	dodging.name = "Dodging"
	state_manager.add_child(dodging)

	var StateStunnedScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/states/state_stunned.gd")
	var stunned = StateStunnedScript.new()
	stunned.name = "Stunned"
	state_manager.add_child(stunned)

	var StateDeadScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/states/state_dead.gd")
	var dead = StateDeadScript.new()
	dead.name = "Dead"
	state_manager.add_child(dead)
	
	var StateDashScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/states/state_dash.gd")
	var dash = StateDashScript.new()
	dash.name = "Dash"
	state_manager.add_child(dash)
	
	var StateAirSlashScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/states/state_air_slash.gd")
	var air_slash = StateAirSlashScript.new()
	air_slash.name = "AirSlash"  # Registered as "airslash" (lowercase) in state manager
	state_manager.add_child(air_slash)

func _physics_process(delta: float):
	# Skip physics if frozen in hitlag (check both variable and meta flag)
	if _is_hitlag_frozen or get_meta("hitlag_frozen", false):
		return
	
	# Process stamina regeneration
	_process_stamina(delta)
	
	# Get current state name for physics decisions
	var current_state_name = ""
	if state_manager and state_manager.has_method("get_current_state_name"):
		current_state_name = state_manager.get_current_state_name()
	
	# Check if current state controls its own velocity (dash, airslash, etc.)
	var state_controls_velocity = current_state_name.to_lower() in ["dash", "dodging", "airslash"]
	
	# Process state physics FIRST so it can set velocity before move_and_slide
	if state_controls_velocity and state_manager and state_manager.current_state:
		state_manager.current_state.on_physics_process(delta)

	# Apply gravity (skip if airborne state or velocity-controlling state is handling it)
	if not is_on_floor() and current_state_name != "airborne" and not state_controls_velocity:
		velocity.y -= gravity * delta

	if state_manager and state_manager.allows_movement():
		_apply_velocity(delta)
	elif not state_controls_velocity:
		# Only decelerate if state doesn't control velocity AND we're on the ground
		# Airborne momentum should be preserved (handled by StateAirborne)
		if is_on_floor():
			velocity.x = move_toward(velocity.x, 0, deceleration * delta)
			velocity.z = move_toward(velocity.z, 0, deceleration * delta)
	
	# Apply knockback velocity with smooth decay
	_apply_knockback_physics(delta)

	move_and_slide()
	
	# Keep entity upright - only Y rotation (facing) should change
	# X/Z tipping from knockback/collision isn't useful for animated characters
	rotation.x = 0
	rotation.z = 0
	
	# Server entity sync - broadcast state periodically
	if is_server_entity and is_server():
		_server_sync_timer += delta
		if _server_sync_timer >= 1.0 / server_sync_rate:
			_server_sync_timer = 0.0
			# Skip sync during knockback/hitstun to avoid overwriting client physics
			if is_hitstunned() or knockback_velocity.length_squared() > 0.001:
				pass  # Don't sync - entity is being knocked back or stunned
			else:
				broadcast_server_entity_state()
	
	# Failsafe: force transition to airborne if we're not on floor and not already airborne
	# SKIP for remote players - their state is synced from network, not local physics
	var is_local_entity = not "can_receive_input" in self or self.can_receive_input or is_server_entity
	if is_local_entity and state_manager and not is_on_floor():
		var current_state = state_manager.get_current_state_name() if state_manager.has_method("get_current_state_name") else ""
		if current_state not in ["airborne", "jumping", "dodging", "dash", "airslash"]:
			if state_manager.has_state("airborne"):
				state_manager.change_state("airborne", true)

	if state_manager and state_manager.allows_rotation():
		_update_rotation(delta)

func _apply_velocity(delta: float):
	var desired_direction = get_movement_input()

	if desired_direction.length() > 0.1 and _last_move_direction.length() > 0.1:
		var angle_diff = rad_to_deg(desired_direction.angle_to(_last_move_direction))

		if current_speed_multiplier > 1.1 and angle_diff > sharp_turn_angle:
			var turn_severity = clampf((angle_diff - sharp_turn_angle) / 90.0, 0.0, 1.0)
			_momentum_multiplier = maxf(_momentum_multiplier - sprint_turn_penalty * turn_severity, 0.3)

	_momentum_multiplier = move_toward(_momentum_multiplier, 1.0, momentum_recovery_speed * delta)

	var effective_multiplier = current_speed_multiplier
	if current_speed_multiplier > 1.1:
		effective_multiplier = lerpf(1.0, current_speed_multiplier, _momentum_multiplier)

	var target_velocity = desired_direction * base_move_speed * effective_multiplier

	if desired_direction.length() > 0.1:
		velocity.x = move_toward(velocity.x, target_velocity.x, acceleration * delta)
		velocity.z = move_toward(velocity.z, target_velocity.z, acceleration * delta)
		_last_move_direction = desired_direction
	else:
		# Only apply ground friction when actually on the ground
		# Airborne momentum is handled by StateAirborne
		if is_on_floor():
			velocity.x = move_toward(velocity.x, 0, deceleration * delta)
			velocity.z = move_toward(velocity.z, 0, deceleration * delta)
		_last_move_direction = Vector3.ZERO
		_momentum_multiplier = 1.0

func _update_rotation(delta: float):
	if face_direction.length() > 0.1:
		var target_rotation = atan2(face_direction.x, face_direction.z)
		rotation.y = lerp_angle(rotation.y, target_rotation, rotation_speed * delta)

#region Movement API
func get_movement_input() -> Vector3:
	# Block movement during hitlag (but camera still works)
	if get_meta("hitlag_no_movement", false) or get_meta("hitlag_frozen", false):
		return Vector3.ZERO
	return move_direction

func set_speed_multiplier(mult: float):
	current_speed_multiplier = mult

func set_facing(direction: Vector3):
	if direction.length() > 0.1:
		face_direction = direction.normalized()

func face_aim_direction():
	pass

func stop_movement():
	move_direction = Vector3.ZERO
	current_speed_multiplier = 1.0
	velocity.x = 0
	velocity.z = 0
#endregion

#region Animation API
# Locomotion animations that should blend smoothly by default
const LOCOMOTION_ANIMS = ["idle", "walk", "run", "fall"]

func play_animation(anim_name: String, blend_time: float = -1.0, snap: bool = false):
	## Play an animation. 
	## blend_time: -1.0 = auto (0.2 for locomotion, 0.0 for actions)
	## snap: true = instant start (for attacks, dash), false = smooth blend
	
	# Check if a custom blend time was requested (e.g., from dash exit)
	var custom_blend = get_meta("next_anim_blend_time", -1.0)
	if custom_blend > 0:
		remove_meta("next_anim_blend_time")
		blend_time = custom_blend
		snap = false
	
	# Auto-determine blend based on animation type
	var is_locomotion = anim_name.to_lower() in LOCOMOTION_ANIMS
	var actual_blend = blend_time
	var actual_snap = snap
	
	if blend_time < 0:
		# Auto mode: locomotion gets smooth blend, actions snap
		actual_blend = 0.2 if is_locomotion else 0.0
		actual_snap = not is_locomotion
	
	# Try AnimationController first (handles nested AnimationPlayer)
	var anim_controller = get_node_or_null("AnimationController")
	if anim_controller and anim_controller.has_method("play_action"):
		anim_controller.play_action(anim_name, actual_blend, actual_snap)
		return
	
	# Try animation tree
	if animation_tree:
		var state_machine = animation_tree.get("parameters/playback")
		if state_machine:
			state_machine.travel(anim_name)
			return
	
	# Try direct AnimationPlayer
	if has_node("AnimationPlayer"):
		var anim_player = get_node("AnimationPlayer") as AnimationPlayer
		var final_blend = 0.0 if actual_snap else actual_blend
		anim_player.play(anim_name, final_blend, 1.0, false)
		return
	
	# Search for AnimationPlayer in hierarchy (for models with embedded AnimationPlayer)
	var anim_player = _find_animation_player(self)
	if anim_player and anim_player.has_animation(anim_name):
		var final_blend = 0.0 if actual_snap else actual_blend
		anim_player.play(anim_name, final_blend, 1.0, false)
	else:
		push_warning("[ActionEntity] Could not play animation '%s' - not found" % anim_name)

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found = _find_animation_player(child)
		if found:
			return found
	return null

func get_animation_progress() -> float:
	if animation_tree:
		var state_machine = animation_tree.get("parameters/playback")
		if state_machine:
			var current_length = state_machine.get_current_length()
			var current_time = state_machine.get_current_play_position()
			return current_time / current_length if current_length > 0 else 0.0
	return 0.0
#endregion

#region Combat API
func take_damage(amount: float, source: Node = null, damage_type: String = "normal") -> float:
	if is_invulnerable:
		return 0.0
	if combat:
		return combat.take_damage(amount, source, damage_type)
	return 0.0

func heal(amount: float, source: Node = null) -> float:
	if combat:
		return combat.heal(amount, source)
	return 0.0

func set_invulnerable(value: bool):
	is_invulnerable = value
	if combat:
		combat.is_invulnerable = value

func should_stagger(damage_amount: float) -> bool:
	return damage_amount >= 10.0

func _apply_knockback_physics(delta: float):
	## Apply knockback velocity with smooth exponential decay
	if knockback_velocity.length_squared() < knockback_min_threshold * knockback_min_threshold:
		knockback_velocity = Vector3.ZERO
		return
	
	# Add knockback to velocity
	velocity += knockback_velocity * delta * 12.0
	
	# Fast exponential decay for quick falloff
	knockback_velocity = knockback_velocity * exp(-knockback_decay_rate * delta)

func apply_knockback(force: Vector3):
	## Start knockback - adds to knockback_velocity with diminishing returns
	## Call this AFTER hitlag ends for proper timing
	if force.length_squared() < 0.01:
		return
	
	# Diminishing returns: if already being knocked back, add less
	var current_kb = knockback_velocity.length()
	if current_kb > 0.1:
		# Scale new force down based on existing knockback (more existing = less added)
		var diminish_factor = 1.0 / (1.0 + current_kb * 2.0)  # At kb=1, factor=0.33; at kb=2, factor=0.2
		force *= diminish_factor
	
	knockback_velocity += force

func apply_hitlag_freeze(duration: float):
	## Freeze this entity during hitlag (animation + physics pause)
	## This is for the ATTACKER only - provides impact feel
	if duration <= 0 or _is_hitlag_frozen:
		return
	
	_is_hitlag_frozen = true
	
	# Pause animation
	var anim_controller = get_node_or_null("AnimationController")
	var anim_player = null
	var original_speed = 1.0
	
	if anim_controller and "animation_player" in anim_controller and anim_controller.animation_player:
		anim_player = anim_controller.animation_player
		original_speed = anim_player.speed_scale
		anim_player.speed_scale = 0.0
	
	# Wait for hitlag duration
	await get_tree().create_timer(duration).timeout
	
	# Unfreeze
	_is_hitlag_frozen = false
	if is_instance_valid(anim_player):
		anim_player.speed_scale = original_speed

func apply_hitstun_then_knockback(hitstun_duration: float, knockback_force: Vector3):
	## Apply hitstun first, then knockback AFTER hitstun ends
	## This creates the proper hit reaction: freeze -> launch
	if hitstun_duration <= 0:
		# No hitstun, apply knockback immediately
		apply_knockback(knockback_force)
		return
	
	set_meta("hitstunned", true)
	
	# Wait for hitstun to end
	await get_tree().create_timer(hitstun_duration).timeout
	
	set_meta("hitstunned", false)
	
	# NOW apply knockback (they launch after the freeze)
	if is_instance_valid(self):
		apply_knockback(knockback_force)

func apply_hitstun(duration: float):
	if duration <= 0:
		return
	set_meta("hitstunned", true)
	
	# Start vibrate effect on mesh
	_start_hitstun_vibrate(duration)
	
	get_tree().create_timer(duration).timeout.connect(func(): set_meta("hitstunned", false))

var _hitstun_vibrate_active: bool = false
var _hitstun_original_pos: Vector3 = Vector3.ZERO

var _hitstun_vibrate_id: int = 0  # Track current vibration instance

func _start_hitstun_vibrate(duration: float):
	## Vibrate the mesh during hitstun for visual feedback
	## New hits reset the vibration (don't stack)
	
	var target_node = mesh_root if mesh_root else get_node_or_null("MeshRoot")
	if not target_node:
		return
	
	# Cancel any existing vibration by incrementing ID
	_hitstun_vibrate_id += 1
	var my_id = _hitstun_vibrate_id
	
	# Reset position if already vibrating
	if _hitstun_vibrate_active and is_instance_valid(target_node):
		target_node.position = _hitstun_original_pos
	
	_hitstun_vibrate_active = true
	_hitstun_original_pos = target_node.position
	
	# Visible vibrate
	var elapsed = 0.0
	var intensity = 0.06  # Noticeable shake
	
	while elapsed < duration and is_instance_valid(target_node) and my_id == _hitstun_vibrate_id:
		# Small random offset that decreases over time
		var factor = 1.0 - (elapsed / duration)
		var offset = Vector3(
			randf_range(-intensity, intensity) * factor,
			0,
			randf_range(-intensity, intensity) * factor
		)
		target_node.position = _hitstun_original_pos + offset
		
		await get_tree().create_timer(0.04).timeout
		elapsed += 0.04
	
	# Only reset if we're still the active vibration
	if my_id == _hitstun_vibrate_id:
		if is_instance_valid(target_node):
			target_node.position = _hitstun_original_pos
		_hitstun_vibrate_active = false

func apply_slow(multiplier: float, duration: float):
	if multiplier >= 1.0 or duration <= 0:
		return
	var original_speed = base_move_speed
	base_move_speed *= multiplier
	get_tree().create_timer(duration).timeout.connect(func(): base_move_speed = original_speed)

func is_hitstunned() -> bool:
	return get_meta("hitstunned", false)

func is_alive() -> bool:
	if combat:
		return combat.is_alive()
	return true

func is_dead() -> bool:
	return not is_alive()

func _on_died(killer: Node):
	if state_manager:
		state_manager.change_state("dead", true)

func _on_damage_taken(amount: float, source: Node, damage_type: String):
	if state_manager:
		state_manager.on_damage_taken(amount, source)
#endregion

#region Stamina API
func _process_stamina(delta: float):
	## Process stamina regeneration - call in _physics_process
	if _is_stamina_draining:
		# Reset regen timer while draining
		_stamina_regen_timer = 0.0
		_is_stamina_draining = false  # Will be set true again if still draining
		return
	
	# Increment regen timer
	_stamina_regen_timer += delta
	
	# Start regenerating after delay
	if _stamina_regen_timer >= stamina_regen_delay:
		if current_stamina < max_stamina:
			var old_stamina = current_stamina
			current_stamina = minf(current_stamina + stamina_regen_rate * delta, max_stamina)
			if current_stamina != old_stamina:
				stamina_changed.emit(current_stamina, max_stamina)

func consume_stamina(amount: float) -> bool:
	## Try to consume stamina. Returns true if successful, false if not enough.
	if current_stamina < amount:
		return false
	
	current_stamina -= amount
	_stamina_regen_timer = 0.0  # Reset regen delay
	stamina_changed.emit(current_stamina, max_stamina)
	return true

func drain_stamina(amount: float) -> bool:
	## Drain stamina continuously (for sprinting). Marks as draining to pause regen.
	## Returns true if stamina remains, false if depleted.
	_is_stamina_draining = true
	
	if current_stamina <= 0:
		return false
	
	current_stamina = maxf(0.0, current_stamina - amount)
	stamina_changed.emit(current_stamina, max_stamina)
	return current_stamina > 0

func restore_stamina(amount: float):
	## Restore stamina (e.g., from parry reward)
	var old_stamina = current_stamina
	current_stamina = minf(current_stamina + amount, max_stamina)
	if current_stamina != old_stamina:
		stamina_changed.emit(current_stamina, max_stamina)

func get_stamina_percent() -> float:
	return current_stamina / max_stamina if max_stamina > 0 else 0.0

func has_stamina(amount: float = 0.1) -> bool:
	return current_stamina >= amount
#endregion

#region Visual Effects
func set_opacity(alpha: float):
	if mesh_root:
		_set_node_opacity(mesh_root, alpha)

func _set_node_opacity(node: Node, alpha: float):
	if node is MeshInstance3D:
		var mesh_instance = node as MeshInstance3D
		for i in mesh_instance.get_surface_override_material_count():
			var mat = mesh_instance.get_surface_override_material(i)
			if mat:
				mat.albedo_color.a = alpha

	for child in node.get_children():
		_set_node_opacity(child, alpha)

func enable_ragdoll(impulse: Vector3 = Vector3.ZERO, impulse_bone: String = ""):
	if ragdoll_controller:
		ragdoll_controller.enable_full_ragdoll(impulse, impulse_bone)

func disable_ragdoll():
	if ragdoll_controller:
		ragdoll_controller.disable_full_ragdoll()

## Apply hit impact for procedural hit reactions (active ragdoll)
func apply_hit_reaction(bone_name: String, hit_direction: Vector3, impact_force: float = 10.0):
	if ragdoll_controller:
		ragdoll_controller.apply_hit_impact(bone_name, hit_direction, impact_force)

## Apply hit at world position - finds closest bone automatically
func apply_hit_reaction_at_position(world_position: Vector3, hit_direction: Vector3, impact_force: float = 10.0):
	if ragdoll_controller:
		ragdoll_controller.apply_hit_at_position(world_position, hit_direction, impact_force)
#endregion

#region Entity Registry
static func get_entity_by_id(id: String):
	if entity_registry.has(id):
		var entity = entity_registry[id]
		if is_instance_valid(entity):
			return entity
		else:
			entity_registry.erase(id)
	return null

static func get_all_entities() -> Array:
	var entities: Array = []
	for entity in entity_registry.values():
		if is_instance_valid(entity):
			entities.append(entity)
	return entities

static func get_entities_in_radius(position: Vector3, radius: float) -> Array:
	var entities: Array = []
	for entity in entity_registry.values():
		if is_instance_valid(entity):
			if entity.global_position.distance_to(position) <= radius:
				entities.append(entity)
	return entities

static func get_entities_on_team(team: int) -> Array:
	var entities: Array = []
	for entity in entity_registry.values():
		if is_instance_valid(entity) and entity.team_id == team:
			entities.append(entity)
	return entities
#endregion

func _exit_tree():
	if entity_id != "" and entity_registry.has(entity_id):
		entity_registry.erase(entity_id)
	entity_despawned.emit()
