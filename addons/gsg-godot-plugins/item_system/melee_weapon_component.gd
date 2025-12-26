extends Node3D
class_name MeleeWeaponComponent

## MeleeWeaponComponent - Handles melee weapon behavior
## Simpler than ranged weapons - just attach to hand bone

#region Signals
signal attack_started()
signal attack_hit(target: Node, hit_info: Dictionary) # Local hit (for prediction/feedback)
signal attack_hit_confirmed(target: Node, hit_info: Dictionary) # Server confirmed hit
signal attack_finished()
#endregion

#region Configuration
@export_group("Weapon Identity")
@export var item_id: String = ""
@export var weapon_name: String = "Melee Weapon"
@export var holster_slot: String = "hip_right"
@export var rarity: String = "common"  # Item rarity for UI display

@export_group("Grip Point")
@export var grip_point: Marker3D # Where hand holds the weapon

@export_group("Combat Stats")
@export var damage: float = 30.0
@export var damage_type: String = "energy"
@export var attack_speed: float = 1.5 # Attacks per second
@export var attack_range: float = 2.0 # Hitbox range

@export_group("Impact Effects")
@export var knockback_force: float = 0.5 # Base knockback, multiplied by combo (reduced for snappier feel)
@export var hitstun_duration: float = 0.3
@export var can_block: bool = true
@export var block_damage_reduction: float = 0.7
@export var impact_effect: PackedScene # Visual effect to spawn on hit

@export_group("Hitbox")
@export var hitbox_size: Vector3 = Vector3(0.3, 0.3, 1.0)
@export var hitbox_offset: Vector3 = Vector3(0, 0, -0.5) # Forward from grip

@export_group("Sound")
@export var hit_sound_path: String = "res://sounds/slash" # Base path for hit sounds (looks for slash_1.wav, slash_2.wav, etc.)
@export var hit_sound_volume: float = 0.0
@export var hit_sound_pitch_variation: float = 0.15 # ±15% pitch variation

@export_group("Debug")
@export var debug_hitbox: bool = false # Show hitbox debug info
#endregion

#region Runtime State
var is_attacking: bool = false
var is_blocking: bool = false
var _attack_cooldown: float = 0.0
var _owner_entity: Node3D = null
var _hitbox: Area3D = null # Public for state access
var _hits_this_swing: Array[Node] = [] # Prevent multi-hit same target, public for state access
var _base_damage: float = 0.0 # Store original damage for combo modifiers
var _base_knockback: float = 0.0 # Store original knockback for combo modifiers
var _base_hitstun: float = 0.0 # Store original hitstun for combo modifiers
#endregion

func _ready():
	# Auto-find grip point
	if not grip_point:
		grip_point = get_node_or_null("GripPoint")
	
	# Store base values for combo modifiers
	_base_damage = damage
	_base_knockback = knockback_force
	_base_hitstun = hitstun_duration
	
	# Find hitbox from scene (preferred) or create dynamically
	_hitbox = get_node_or_null("BladeHitbox")
	if _hitbox:
		# Connect signals if not already connected
		if not _hitbox.body_entered.is_connected(_on_hitbox_body_entered):
			_hitbox.body_entered.connect(_on_hitbox_body_entered)
		if not _hitbox.area_entered.is_connected(_on_hitbox_area_entered):
			_hitbox.area_entered.connect(_on_hitbox_area_entered)
		# Ensure debug mesh visibility matches setting
		var debug_mesh = _hitbox.get_node_or_null("DebugMesh")
		if debug_mesh:
			debug_mesh.visible = false # Always start hidden
		if debug_hitbox:
			print("[MeleeWeapon] Found BladeHitbox in scene, mask=%d" % _hitbox.collision_mask)

func _process(delta: float):
	if _attack_cooldown > 0:
		_attack_cooldown -= delta
	
	# Show debug mesh when hitbox is active
	if debug_hitbox and _hitbox:
		var debug_mesh = _hitbox.get_node_or_null("DebugMesh")
		if debug_mesh:
			debug_mesh.visible = _hitbox.monitoring

func _create_hitbox():
	## Find hitbox from scene or create dynamically as fallback
	# Already have a hitbox from scene
	if _hitbox and is_instance_valid(_hitbox):
		if debug_hitbox:
			print("[MeleeWeapon] Using existing hitbox from scene")
		return
	
	# Try to find hitbox in scene
	_hitbox = get_node_or_null("BladeHitbox")
	if _hitbox:
		if not _hitbox.body_entered.is_connected(_on_hitbox_body_entered):
			_hitbox.body_entered.connect(_on_hitbox_body_entered)
		if not _hitbox.area_entered.is_connected(_on_hitbox_area_entered):
			_hitbox.area_entered.connect(_on_hitbox_area_entered)
		if debug_hitbox:
			print("[MeleeWeapon] Found BladeHitbox in scene")
		return
	
	# Fallback: create hitbox dynamically on owner entity
	if not _owner_entity:
		push_warning("[MeleeWeaponComponent] Can't create hitbox without owner entity")
		return
	
	if debug_hitbox:
		print("[MeleeWeapon] Creating dynamic hitbox (no BladeHitbox in scene)")
	
	_hitbox = Area3D.new()
	_hitbox.name = "MeleeHitbox_" + item_id
	_hitbox.collision_layer = 0
	_hitbox.collision_mask = 2 | 4 # Players (layer 2) + Enemies (layer 3)
	_hitbox.monitoring = false
	_hitbox.monitorable = false
	
	# Add to weapon so it follows the blade
	add_child(_hitbox)
	
	# Create capsule shape for the blade
	var shape = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = 0.2
	capsule.height = attack_range
	shape.shape = capsule
	shape.rotation_degrees.x = 90 # Align with blade (-Z)
	shape.position = Vector3(0, 0, -attack_range * 0.5)
	_hitbox.add_child(shape)
	
	_hitbox.body_entered.connect(_on_hitbox_body_entered)
	_hitbox.area_entered.connect(_on_hitbox_area_entered)
	
	if debug_hitbox:
		print("[MeleeWeapon] Created dynamic hitbox: radius=%.2f, length=%.2f" % [capsule.radius, attack_range])

#region Combat
func try_attack() -> bool:
	## Attempt to start an attack - delegates to combo controller if available
	if is_attacking or _attack_cooldown > 0:
		return false
	
	# Check for combo controller on owner
	if _owner_entity:
		var combo_ctrl = _owner_entity.get_node_or_null("MeleeComboController")
		if combo_ctrl:
			return combo_ctrl.try_attack(default_combo)
	
	# Fallback: simple attack
	_start_simple_attack()
	return true

@export var default_combo: String = "saber_light"

func _start_simple_attack():
	## Simple attack without combo system (fallback)
	is_attacking = true
	_hits_this_swing.clear()
	_hitbox.monitoring = true
	attack_started.emit()
	
	# Attack duration based on speed
	var attack_duration = 0.4 / attack_speed # Swing time
	await get_tree().create_timer(attack_duration).timeout
	
	_end_simple_attack()

func _end_simple_attack():
	is_attacking = false
	_hitbox.monitoring = false
	_attack_cooldown = 1.0 / attack_speed
	attack_finished.emit()

func set_attacking(attacking: bool):
	## Called by combo states to control attack state
	is_attacking = attacking
	if not attacking:
		_attack_cooldown = 1.0 / attack_speed
		# Reset stats to base values when attack ends
		reset_combat_stats()

func reset_combat_stats():
	## Reset all combat stats to their base values
	damage = _base_damage
	knockback_force = _base_knockback
	hitstun_duration = _base_hitstun

func start_block():
	if not can_block:
		return
	is_blocking = true

func stop_block():
	is_blocking = false

func set_aiming(aiming: bool):
	## Melee weapons don't aim like guns, but we accept the call
	## Could be used for stance changes in the future
	pass

func _on_hitbox_body_entered(body: Node3D):
	if debug_hitbox:
		print("[MeleeWeapon] Hitbox touched body: %s (layer=%d)" % [body.name, body.collision_layer if "collision_layer" in body else -1])
	_process_hit(body)

func _on_hitbox_area_entered(area: Area3D):
	if debug_hitbox:
		print("[MeleeWeapon] Hitbox touched area: %s" % area.name)
	# Check if this is a bone hitbox
	if area.has_meta("bone_name"):
		var owner = area.get_parent()
		while owner and not owner.has_method("take_damage"):
			owner = owner.get_parent()
		if owner:
			_process_hit(owner, area.get_meta("bone_name"))

func _process_hit(target: Node, bone_name: String = ""):
	# Don't hit self
	if target == _owner_entity:
		if debug_hitbox:
			print("[MeleeWeapon] Ignoring self-hit")
		return

	# Check zone permissions - skip player hits if PvP/combat is disabled
	if _owner_entity and _owner_entity.has_method("can_damage_player"):
		if not _owner_entity.can_damage_player(target):
			if debug_hitbox:
				print("[MeleeWeapon] Ignoring hit - zone doesn't allow PvP/combat")
			return

	# Don't hit same target twice in one swing
	if target in _hits_this_swing:
		if debug_hitbox:
			print("[MeleeWeapon] Already hit %s this swing" % target.name)
		return
	_hits_this_swing.append(target)
	
	if debug_hitbox:
		print("[MeleeWeapon] HIT! Target: %s, Damage: %.1f" % [target.name, damage])
	
	# Calculate hit direction
	var hit_dir = Vector3.ZERO
	if target is Node3D:
		hit_dir = (target.global_position - _owner_entity.global_position).normalized()
	
	var hit_info = {
		"damage": damage,
		"damage_type": damage_type,
		"knockback_force": knockback_force,
		"knockback_direction": hit_dir,
		"hitstun_duration": hitstun_duration,
		"bone_name": bone_name,
		"attacker": _owner_entity,
		"target": target
	}
	
	# Check if we're the server or if this is OUR attack (local player)
	var network = _owner_entity.get_node_or_null("/root/NetworkManager")
	var is_server = not network or network.is_server
	var is_local_attacker = "can_receive_input" in _owner_entity and _owner_entity.can_receive_input
	
	# Apply damage/effects immediately for:
	# 1. Server (authoritative)
	# 2. Local player attacks (client-authoritative for responsiveness)
	if is_server or is_local_attacker:
		print("[MeleeWeapon] Applying hit effects (server=%s, local=%s)" % [is_server, is_local_attacker])
		_apply_authoritative_hit(target, hit_info)
		
		# If we're a client, also notify server for validation
		if not is_server:
			_request_server_hit_validation(target, hit_info)
	else:
		# Remote player attack on client - wait for server
		_apply_predicted_hit(target, hit_info)

func _apply_predicted_hit(target: Node, hit_info: Dictionary):
	## CLIENT-SIDE: Immediate feedback for responsiveness
	## This is a "lie" - server will confirm or deny
	# Emit signal for VFX/SFX (particles, sounds, screen shake)
	attack_hit.emit(target, hit_info)
	
	# Could show predicted damage number here
	# Could play predicted flinch animation on target
	# These are cosmetic and will be corrected if server disagrees

func _apply_authoritative_hit(target: Node, hit_info: Dictionary):
	## SERVER-SIDE: Real damage, knockback, hitstun
	## Checks for blocking/parrying first
	# Check if target is blocking
	var block_result = _check_target_blocking(target, hit_info)
	
	if block_result.get("parried", false):
		# We got parried! The block state already applied effects to us
		hit_info["was_parried"] = true
		attack_hit.emit(target, hit_info)
		return
	
	if block_result.get("blocked", false):
		# Attack was blocked
		hit_info["was_blocked"] = true
		hit_info["damage"] = block_result.get("damage_taken", 0.0)
		
		if block_result.get("guard_broken", false):
			# Guard broken - full damage goes through
			hit_info["guard_broken"] = true
		
		attack_hit.emit(target, hit_info)
		attack_hit_confirmed.emit(target, hit_info)
		return
	
	# Unblocked hit - apply damage first, then hitlag, then knockback
	print("[MeleeWeapon] Applying damage %.1f to %s" % [hit_info.damage, target.name])
	if target.has_method("take_damage"):
		target.take_damage(hit_info.damage, _owner_entity, hit_info.damage_type)
	else:
		print("[MeleeWeapon] WARNING: Target has no take_damage method!")
	
	# Play hit sound at impact point
	_play_hit_sound(target)

	# Spawn visual impact effect
	_spawn_impact_effect(target)

	# Apply hitstun immediately (target can't act)
	if target.has_method("apply_hitstun"):
		target.apply_hitstun(hit_info.hitstun_duration)
	
	# Apply hitlag FIRST (freeze attacker), THEN apply knockback after
	_apply_hitlag_then_knockback(target, hit_info)
	
	attack_hit_confirmed.emit(target, hit_info)
	attack_hit.emit(target, hit_info)

func _check_target_blocking(target: Node, hit_info: Dictionary) -> Dictionary:
	## Check if target is blocking and handle block/parry
	var result = {"blocked": false, "parried": false}
	
	# Find target's bone hitbox system
	var bone_system = target.get_node_or_null("BoneHitboxSystem")
	if not bone_system or not bone_system.is_blocking():
		return result
	
	# Check if the hit bone is blockable (above knees)
	var bone_name = hit_info.get("bone_name", "")
	if bone_name != "" and not bone_system.is_bone_blockable(bone_name):
		# Hit below knees - can't block
		return result
	
	# Check if attack is from the front (can't block attacks from behind)
	if _owner_entity and bone_system.has_method("is_attack_from_front"):
		if not bone_system.is_attack_from_front(_owner_entity.global_position):
			# Attack from behind - can't block
			return result
	
	# Get the block state for parry check
	var block_state = bone_system.get_block_state()
	if block_state and block_state.has_method("on_melee_blocked"):
		result = block_state.on_melee_blocked(_owner_entity, hit_info.damage, hit_info)
	else:
		# Fallback: simple block without parry
		result["blocked"] = true
		result["damage_taken"] = hit_info.damage * 0.3 # 70% reduction
	
	return result

func _request_server_hit_validation(target: Node, hit_info: Dictionary):
	## CLIENT: Ask server to validate this hit
	var network = _owner_entity.get_node_or_null("/root/NetworkManager")
	if not network:
		return
	
	# Get target's network ID - try multiple methods
	var target_id = -1
	if "peer_id" in target:
		target_id = target.peer_id
	elif target.has_method("get_network_id"):
		target_id = target.get_network_id()
	else:
		# Fallback to instance ID for server entities
		target_id = target.get_instance_id()
	
	if target_id < 0:
		return # Can't validate hits on non-networked entities
	
	# Send hit request to server
	# Server will validate timing, range, and apply real damage + knockback
	if network.has_method("request_melee_hit"):
		network.request_melee_hit({
			"target_id": target_id,
			"target_name": target.name, # Fallback for entity lookup
			"weapon_id": item_id,
			"damage": hit_info.damage,
			"damage_type": hit_info.get("damage_type", "melee"),
			"knockback_force": hit_info.get("knockback_force", 0.0),
			"knockback_direction": hit_info.get("knockback_direction", Vector3.ZERO),
			"hitstun_duration": hit_info.get("hitstun_duration", 0.0),
			"bone_name": hit_info.get("bone_name", ""),
			"timestamp": Time.get_ticks_msec()
		})

func _play_hit_sound(target: Node):
	## Play hit sound at target position using SoundManager
	if hit_sound_path.is_empty():
		print("[MeleeWeapon] Hit sound path is empty!")
		return
	
	var sound_manager = get_node_or_null("/root/SoundManager")
	if not sound_manager:
		print("[MeleeWeapon] SoundManager not found!")
		return
	
	# Get hit position (target's position or weapon position)
	var hit_position = Vector3.ZERO
	if target is Node3D:
		hit_position = target.global_position
	elif _owner_entity:
		hit_position = _owner_entity.global_position
	
	# Play 3D sound with variation and random pitch
	if sound_manager.has_method("play_sound_3d_with_variation"):
		print("[MeleeWeapon] Playing hit sound: %s at %s" % [hit_sound_path, hit_position])
		sound_manager.play_sound_3d_with_variation(
			hit_sound_path,
			hit_position,
			null,
			hit_sound_volume,
			hit_sound_pitch_variation
		)
	else:
		print("[MeleeWeapon] SoundManager missing play_sound_3d_with_variation method!")

func _spawn_impact_effect(target: Node):
	## Spawn visual impact effect at hit location
	if not impact_effect:
		return

	# Get hit position
	var hit_position = Vector3.ZERO
	if target is Node3D:
		hit_position = target.global_position
	elif _owner_entity:
		hit_position = _owner_entity.global_position

	# Spawn effect
	var effect = impact_effect.instantiate()
	get_tree().current_scene.add_child(effect)
	effect.global_position = hit_position

	if debug_hitbox:
		print("[MeleeWeapon] Spawned impact effect at: %s" % hit_position)

func take_blocked_damage(incoming_damage: float) -> float:
	## Called when blocking an attack, returns damage that gets through
	if is_blocking:
		return incoming_damage * (1.0 - block_damage_reduction)
	return incoming_damage

func _apply_hitlag_then_knockback(target: Node, hit_info: Dictionary):
	## Apply hitlag to ATTACKER (freeze animation)
	## KNOCKBACK applied locally for responsiveness
	## Timeline:
	##   Hit -> Hitlag (attacker freezes) -> Knockback applied
	##   Hitstun is longer and persists into knockback
	var hit_damage_type = hit_info.get("damage_type", "melee")
	
	# Check if this is a local player attack - if so, apply knockback directly
	var is_local_attack = "can_receive_input" in _owner_entity or (_owner_entity.has_method("get_meta") and _owner_entity.get_meta("_is_local", false))
	
	# Check if target wants hitlag for this damage type
	if target.has_method("should_apply_hitlag_for_type"):
		if not target.should_apply_hitlag_for_type(hit_damage_type):
			# No hitlag - server handles knockback
			return
	
	var hitlag_duration = 0.1 # Default - slightly longer for visibility
	
	if target.has_method("get_hitlag_duration"):
		hitlag_duration = target.get_hitlag_duration()
	
	if hitlag_duration <= 0:
		# No hitlag - server handles knockback
		return
	
	print("[MeleeWeapon] Applying hitlag (%.2fs) - knockback handled by server" % hitlag_duration)
	
	# Find animation player on attacker (owner)
	var anim_controller = _owner_entity.get_node_or_null("AnimationController")
	print("[MeleeWeapon] AnimController=%s, has anim_player=%s" % [
		anim_controller != null,
		anim_controller.animation_player != null if anim_controller and "animation_player" in anim_controller else false
	])
	
	if anim_controller and "animation_player" in anim_controller and anim_controller.animation_player:
		var anim_player = anim_controller.animation_player
		
		# Pause attacker animation
		var original_speed = anim_player.speed_scale
		anim_player.speed_scale = 0.0
		
		# Freeze attacker movement (but not camera)
		var saved_velocity = Vector3.ZERO
		if _owner_entity is CharacterBody3D:
			saved_velocity = _owner_entity.velocity
			_owner_entity.velocity = Vector3.ZERO
		
		# Disable movement input during hitlag (but NOT camera - that causes jitter)
		# We set a flag instead of disabling can_receive_input entirely
		if _owner_entity.has_method("set_meta"):
			_owner_entity.set_meta("hitlag_no_movement", true)
		
		# Set frozen flag for physics
		if _owner_entity.has_method("set_meta"):
			_owner_entity.set_meta("hitlag_frozen", true)
		
		print("[MeleeWeapon] HITLAG: Player frozen for %.2fs" % hitlag_duration)
		
		# Wait for hitlag duration
		await _owner_entity.get_tree().create_timer(hitlag_duration).timeout
		
		# Unfreeze
		if _owner_entity.has_method("set_meta"):
			_owner_entity.set_meta("hitlag_frozen", false)
		
		# Restore movement input
		if _owner_entity.has_method("set_meta") and is_instance_valid(_owner_entity):
			_owner_entity.set_meta("hitlag_no_movement", false)
		
		# Restore attacker velocity
		if is_instance_valid(_owner_entity) and _owner_entity is CharacterBody3D and is_attacking:
			_owner_entity.velocity = saved_velocity
		
		# Restore attacker animation speed
		if is_attacking and is_instance_valid(anim_player):
			anim_player.speed_scale = original_speed
		
		print("[MeleeWeapon] HITLAG: Player unfrozen")
	else:
		print("[MeleeWeapon] HITLAG: No anim controller, just waiting")
		await _owner_entity.get_tree().create_timer(hitlag_duration).timeout
	
	# Knockback is server-authoritative - don't apply locally
	# Server will apply knockback and broadcast to all clients for consistency
	print("[MeleeWeapon] HITLAG complete - server handles knockback")
#endregion

#region Setup
func set_weapon_owner(entity: Node3D):
	_owner_entity = entity
	# Store base values for combo modifiers
	_base_damage = damage
	_base_knockback = knockback_force
	_base_hitstun = hitstun_duration
	
	if debug_hitbox:
		print("[MeleeWeapon] set_weapon_owner called for %s" % entity.name)
	
	# Create hitbox - defer to ensure we're in tree
	call_deferred("_create_hitbox")

func load_from_database(weapon_data: Dictionary):
	## Initialize from ItemDatabase data
	item_id = weapon_data.get("item_id", item_id)
	weapon_name = weapon_data.get("name", weapon_name)
	holster_slot = weapon_data.get("holster_slot", holster_slot)
	rarity = weapon_data.get("rarity", rarity)

	# Combat stats
	damage = weapon_data.get("damage", damage)
	damage_type = weapon_data.get("damage_type", damage_type)
	attack_speed = weapon_data.get("attack_speed", attack_speed)
	attack_range = weapon_data.get("attack_range", attack_range)
	
	# Impact
	knockback_force = weapon_data.get("knockback_force", knockback_force)
	hitstun_duration = weapon_data.get("hitstun_duration", hitstun_duration)
	
	# Blocking
	can_block = weapon_data.get("can_block", can_block)
	block_damage_reduction = weapon_data.get("block_damage_reduction", block_damage_reduction)

func get_grip_transform() -> Transform3D:
	if grip_point:
		return grip_point.global_transform
	return global_transform
#endregion
