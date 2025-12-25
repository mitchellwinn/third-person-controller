extends "res://addons/gsg-godot-plugins/action_entities/scripts/action_entity.gd"
class_name PunchingBag

## PunchingBag - Simple enemy for testing combat
## Can now actually die and drop credits!

signal credits_dropped(amount: int, position: Vector3)

#region Hitlag Configuration (attacker feedback)
@export_group("Hitlag")
@export var hitlag_duration: float = 0.15  # How long attacker freezes on hit
@export var hitlag_on_ranged: bool = false  # Apply hitlag for ranged attacks too
#endregion

#region Death & Loot
@export_group("Death & Loot")
@export var can_die: bool = true  # Set to false for infinite HP punching bag
@export var max_hp: float = 500.0

## Loot explosion settings
@export_group("Loot Drops")
@export var drop_big_credit: bool = true
@export var big_credit_amount: int = 30
@export var small_credit_count: int = 8  # How many small pickups
@export var small_credit_amount: int = 5
@export var explosion_force_min: float = 1.0  # Gentle scatter
@export var explosion_force_max: float = 2.0  # Max scatter force
@export var explosion_upward_bias: float = 0.4  # Slight upward arc
#endregion

#region Auto Respawn
@export_group("Auto Respawn")
@export var auto_respawn: bool = true
@export var respawn_time: float = 5.0

var _respawn_timer: float = 0.0
var _spawn_position: Vector3 = Vector3.ZERO
var _is_dead_state: bool = false
#endregion

func _ready():
	# Mark as server entity BEFORE calling super
	is_server_entity = true

	super._ready()

	# Store spawn position for respawn
	_spawn_position = global_position

	# Add to groups for targeting
	add_to_group("enemies")
	add_to_group("hittable")
	add_to_group("syncable_entities")  # For late-join state sync

	# Setup combat component
	if combat:
		if not combat.died.is_connected(_on_punching_bag_died):
			combat.died.connect(_on_punching_bag_died)

		if can_die:
			combat.max_health = max_hp
			combat.current_health = max_hp
			# Give some shields too
			combat.max_shields = max_hp * 0.5
			combat.current_shields = combat.max_shields
		else:
			# Infinite HP mode
			combat.max_health = INF
			combat.current_health = INF

	# Connect to NetworkManager for late-join sync
	if is_server():
		var network = get_node_or_null("/root/NetworkManager")
		if network and network.has_signal("player_spawned"):
			network.player_spawned.connect(_on_player_joined_for_sync)

	print("[PunchingBag] Ready at %s (HP: %.0f, can_die: %s)" % [global_position, max_hp if can_die else INF, can_die])

func _process(_delta: float):
	# Lock rotation EVERY FRAME in _process too
	rotation.x = 0
	rotation.z = 0

func _physics_process(delta: float):
	# FORCE rotation to zero BEFORE parent does anything
	rotation.x = 0
	rotation.z = 0

	super._physics_process(delta)

	# FORCE rotation to zero AFTER parent - absolutely no tipping allowed
	rotation.x = 0
	rotation.z = 0

	# Server-only: handle auto respawn timer
	if is_server() and auto_respawn and _is_dead_state:
		_respawn_timer -= delta
		if int(_respawn_timer * 10) % 10 == 0:  # Log every ~1 second
			print("[PunchingBag] Respawn countdown: %.1f" % _respawn_timer)
		if _respawn_timer <= 0:
			print("[PunchingBag] Respawn timer hit 0, calling _respawn()")
			_respawn()

#region Hitlag Interface
func get_hitlag_duration() -> float:
	return hitlag_duration

func should_apply_hitlag_for_type(damage_type: String) -> bool:
	if damage_type in ["ranged", "projectile", "bullet", "energy_small", "energy_medium", "energy_large"]:
		return hitlag_on_ranged
	return true  # Melee always gets hitlag
#endregion

#region Combat Override
func take_damage(amount: float, source: Node = null, damage_type: String = "normal") -> float:
	if not can_die:
		# Infinite HP mode - just log and return
		print("[PunchingBag] Hit for %.1f damage (ignored - infinite HP)" % amount)
		return 0.0
	
	# Let parent handle damage normally
	var actual_damage = super.take_damage(amount, source, damage_type)
	print("[PunchingBag] Took %.1f damage (HP: %.1f/%.1f)" % [actual_damage, combat.current_health if combat else 0, combat.max_health if combat else 0])
	return actual_damage

func apply_knockback(force: Vector3):
	## Override to only take horizontal knockback - prevents being launched into the air
	## Punching bags stay grounded but can still be pushed sideways
	force.y = 0  # Zero out vertical component
	super.apply_knockback(force)
#endregion

#region Death & Loot
func _on_punching_bag_died(_killer: Node):
	print("[PunchingBag] _on_punching_bag_died called! is_server=%s, _is_dead_state=%s" % [is_server(), _is_dead_state])
	if _is_dead_state:
		print("[PunchingBag] Already dead, skipping")
		return  # Already dead

	_is_dead_state = true
	print("[PunchingBag] Set _is_dead_state = true")

	if auto_respawn:
		_respawn_timer = respawn_time
		print("[PunchingBag] Set respawn timer to %.1f" % respawn_time)

	# Drop credits (server only)
	if is_server():
		_drop_loot()

	# Apply death visuals locally
	_apply_death_visuals()

	# Sync death state to all clients
	if is_server() and multiplayer and multiplayer.has_multiplayer_peer():
		print("[PunchingBag] Broadcasting death to clients")
		_rpc_sync_death.rpc()

	print("[PunchingBag] Died! Dropping loot and respawning in %.1fs" % respawn_time)

@rpc("authority", "call_remote", "reliable")
func _rpc_sync_death():
	## Client receives death state from server
	if _is_dead_state:
		return  # Already applied
	_is_dead_state = true
	_apply_death_visuals()

func _apply_death_visuals():
	## Apply visual changes when dying (shared by server and clients)
	# Hide mesh
	var mesh_root = get_node_or_null("MeshRoot")
	if mesh_root:
		mesh_root.visible = false
	
	# Disable collision
	var collision = get_node_or_null("CollisionShape3D")
	if collision:
		collision.disabled = true

func _drop_loot():
	## Spawn credit pickups in an explosion pattern (server only, broadcasts to clients)
	var total_credits = 0
	var credit_spawns: Array = []  # Collect spawn data for broadcast
	
	# Spawn big credit first (center of explosion, goes up higher)
	if drop_big_credit:
		var spawn_data = _spawn_credit_explosion(big_credit_amount, 0, 1, true)
		if spawn_data:
			credit_spawns.append(spawn_data)
		total_credits += big_credit_amount
	
	# Spawn small credits in a ring pattern
	for i in range(small_credit_count):
		var spawn_data = _spawn_credit_explosion(small_credit_amount, i, small_credit_count, false)
		if spawn_data:
			credit_spawns.append(spawn_data)
		total_credits += small_credit_amount
	
	# Broadcast credit spawns to all clients
	if multiplayer and multiplayer.has_multiplayer_peer() and credit_spawns.size() > 0:
		_rpc_spawn_credits.rpc(credit_spawns)
	
	credits_dropped.emit(total_credits, global_position)
	print("[PunchingBag] Dropped %d credits (%d big + %d small)" % [total_credits, big_credit_amount if drop_big_credit else 0, small_credit_count * small_credit_amount])

@rpc("authority", "call_remote", "reliable")
func _rpc_spawn_credits(spawns: Array):
	## Client receives credit spawn data and creates them locally
	for data in spawns:
		_spawn_credit_on_client(data)

func _spawn_credit_explosion(amount: int, index: int, total_count: int, is_big: bool) -> Dictionary:
	## Spawn a credit pickup with explosive force. Returns spawn data for network sync.
	var credit_scene = load("res://prefabs/pickups/dropped_credits.tscn")
	if not credit_scene:
		push_error("[PunchingBag] Could not load dropped_credits.tscn")
		return {}
	
	var credits = credit_scene.instantiate()
	credits.credit_amount = amount
	credits.quantity = amount
	
	# Calculate spawn position BEFORE adding to scene
	var spawn_pos = global_position + Vector3.UP * 0.8
	# Add small random offset to prevent overlap
	spawn_pos += Vector3(randf_range(-0.1, 0.1), 0, randf_range(-0.1, 0.1))
	
	# Calculate explosion direction BEFORE adding to scene
	var direction: Vector3
	var force: float
	
	if is_big:
		# Big credit goes mostly up with slight random horizontal
		direction = Vector3(
			randf_range(-0.2, 0.2),
			1.0,
			randf_range(-0.2, 0.2)
		).normalized()
		force = explosion_force_max * 1.2  # Extra force for the big one
	else:
		# Small credits explode outward in a ring pattern with upward bias
		var angle = (float(index) / float(total_count)) * TAU
		# Add randomness to angle
		angle += randf_range(-0.3, 0.3)
		
		direction = Vector3(
			cos(angle),
			explosion_upward_bias + randf_range(0, 0.3),
			sin(angle)
		).normalized()
		force = randf_range(explosion_force_min, explosion_force_max)
	
	# Add to scene first
	var scene_root = get_tree().current_scene
	if not scene_root:
		credits.queue_free()
		return {}
	
	scene_root.add_child(credits)
	
	# Now set position after it's in the tree
	credits.global_position = spawn_pos
	
	# Apply force immediately after physics frame (ensures RigidBody is ready)
	call_deferred("_apply_credit_force", credits, direction, force)
	
	# Return spawn data for network broadcast
	return {
		"amount": amount,
		"position": spawn_pos,
		"direction": direction,
		"force": force
	}

func _apply_credit_force(credits: Node, direction: Vector3, force: float):
	## Helper to apply physics force to credits after they're in the scene
	if not is_instance_valid(credits) or not credits.is_inside_tree():
		return
	
	if credits.has_method("drop_with_force"):
		credits.drop_with_force(direction, force)

func _spawn_credit_on_client(data: Dictionary):
	## Client-side credit spawning from network data
	var credit_scene = load("res://prefabs/pickups/dropped_credits.tscn")
	if not credit_scene:
		return
	
	var credits = credit_scene.instantiate()
	credits.credit_amount = data.get("amount", 5)
	credits.quantity = data.get("amount", 5)
	
	var scene_root = get_tree().current_scene
	if not scene_root:
		credits.queue_free()
		return
	
	scene_root.add_child(credits)
	credits.global_position = data.get("position", Vector3.ZERO)
	
	# Apply the same force that server calculated
	var direction = data.get("direction", Vector3.UP)
	var force = data.get("force", 5.0)
	call_deferred("_apply_credit_force", credits, direction, force)
#endregion

#region Respawn
func _respawn():
	_is_dead_state = false
	
	if combat:
		combat.is_dead = false
		combat.current_health = combat.max_health
		combat.current_shields = combat.max_shields
	
	global_position = _spawn_position
	velocity = Vector3.ZERO
	
	# Apply respawn visuals locally
	_apply_respawn_visuals()
	
	# Sync respawn state to all clients
	if is_server() and multiplayer and multiplayer.has_multiplayer_peer():
		_rpc_sync_respawn.rpc(_spawn_position)
	
	print("[PunchingBag] Respawned!")

@rpc("authority", "call_remote", "reliable")
func _rpc_sync_respawn(spawn_pos: Vector3):
	## Client receives respawn state from server
	_is_dead_state = false
	global_position = spawn_pos
	velocity = Vector3.ZERO
	
	if combat:
		combat.is_dead = false
		combat.current_health = combat.max_health
		combat.current_shields = combat.max_shields
	
	_apply_respawn_visuals()

func _apply_respawn_visuals():
	## Apply visual changes when respawning (shared by server and clients)
	# Show mesh
	var mesh_root = get_node_or_null("MeshRoot")
	if mesh_root:
		mesh_root.visible = true
	
	# Enable collision
	var collision = get_node_or_null("CollisionShape3D")
	if collision:
		collision.disabled = false
	
	# Reset state machine
	if state_manager:
		state_manager.change_state("idle", true)
#endregion

#region Utility
func is_dead() -> bool:
	return _is_dead_state or (combat and combat.is_dead)
#endregion

#region Late-Join State Sync
func _on_player_joined_for_sync(peer_id: int, player_entity: Node):
	## Server: When a new player joins, sync current state to them
	if not is_server():
		return

	# Check if player is in the same zone as this punching bag
	var my_zone = _get_my_zone_id()
	var player_zone = _get_entity_zone_id(player_entity)
	if my_zone.is_empty() or player_zone.is_empty() or my_zone != player_zone:
		return  # Different zones, don't sync

	# Only sync if dead (alive is the default state)
	if _is_dead_state:
		# Small delay to ensure client is ready
		await get_tree().create_timer(0.5).timeout
		if is_instance_valid(self) and multiplayer and multiplayer.has_multiplayer_peer():
			_rpc_sync_full_state.rpc_id(peer_id, _is_dead_state, _respawn_timer)
			print("[PunchingBag] Synced dead state to late-joining peer %d" % peer_id)

func _get_my_zone_id() -> String:
	## Walk up tree to find zone_id meta
	var node = self
	while node:
		if node.has_meta("zone_id"):
			return node.get_meta("zone_id")
		node = node.get_parent()
	return ""

func _get_entity_zone_id(entity: Node) -> String:
	## Walk up tree to find zone_id meta for another entity
	var node = entity
	while node:
		if node.has_meta("zone_id"):
			return node.get_meta("zone_id")
		node = node.get_parent()
	return ""

@rpc("authority", "call_remote", "reliable")
func _rpc_sync_full_state(is_dead: bool, respawn_remaining: float):
	## Client receives full state from server on late join
	_is_dead_state = is_dead
	_respawn_timer = respawn_remaining

	if is_dead:
		_apply_death_visuals()
	else:
		_apply_respawn_visuals()

	print("[PunchingBag] Received state sync: dead=%s, respawn_in=%.1f" % [is_dead, respawn_remaining])
#endregion
