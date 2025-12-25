extends ProjectileBase
class_name GrenadeProjectile

## Grenade projectile - arcs through the air and explodes on impact
## Deals radius damage with falloff based on distance from epicenter

@export_group("Explosion")
@export var explosion_radius: float = 5.0  # Damage radius
@export var explosion_damage: float = 80.0  # Max damage at center
@export var explosion_knockback: float = 25.0  # Max knockback at center
@export var explosion_hitstun: float = 0.5  # Max hitstun at center
@export var min_damage_percent: float = 0.2  # Minimum damage at edge (20%)
@export var explosion_effect: PackedScene  # Visual explosion effect
@export var explosion_sound: String = "res://sounds/explosion"

func _on_projectile_ready():
	# Grenades arc and are slower
	speed = 30.0
	damage = 0.0  # Damage is handled by explosion, not direct hit
	damage_type = "explosive"
	lifetime = 10.0  # Long lifetime in case it bounces
	arm_time = 0.0  # Explode immediately on contact
	knockback_force = 0.0  # Knockback is handled by explosion
	hitstun_duration = 0.0
	
	# Grenades have gravity and can bounce
	use_gravity = true
	gravity_scale = 1.5  # Slightly heavier feel
	max_bounces = 0  # Explode on first contact (set > 0 for bouncing grenades)
	destroy_on_hit = true
	
	debug_projectile = false

func _on_hit(body: Node, hit_pos: Vector3, _hit_normal: Vector3):
	# Explode!
	_explode(hit_pos)

func _on_lifetime_expired():
	# Explode when lifetime runs out (for bouncing grenades that never hit anything)
	_explode(global_position)

func _explode(epicenter: Vector3):
	## Create explosion at position, damaging all entities in radius
	if debug_projectile:
		print("[Grenade] EXPLODING at %s, radius=%.1f" % [epicenter, explosion_radius])
	
	# Spawn explosion visual effect
	_spawn_explosion_effect(epicenter)
	
	# Play explosion sound
	_play_explosion_sound(epicenter)
	
	# Find all entities in explosion radius
	var space_state = get_world_3d().direct_space_state
	var targets_hit: Array[Node] = []
	
	# Use a sphere query to find all bodies in radius
	var shape = SphereShape3D.new()
	shape.radius = explosion_radius
	
	var query = PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, epicenter)
	query.collision_mask = collision_mask_layers
	
	var results = space_state.intersect_shape(query, 32)  # Max 32 hits
	
	for result in results:
		var collider = result.collider
		if collider == null:
			continue
		if collider == owner_entity:
			continue  # Don't damage self
		if collider in targets_hit:
			continue  # Already processed
		
		# Calculate distance-based falloff
		var target_pos = collider.global_position if collider is Node3D else epicenter
		var distance = epicenter.distance_to(target_pos)
		var falloff = _calculate_falloff(distance)
		
		if falloff > 0:
			targets_hit.append(collider)
			_apply_explosion_damage(collider, epicenter, falloff)
	
	if debug_projectile:
		print("[Grenade] Hit %d targets" % targets_hit.size())

func _calculate_falloff(distance: float) -> float:
	## Calculate damage/knockback multiplier based on distance from epicenter
	## Returns 1.0 at center, min_damage_percent at edge, 0 outside radius
	if distance >= explosion_radius:
		return 0.0
	
	# Linear falloff from center to edge
	var normalized_distance = distance / explosion_radius
	var falloff = 1.0 - normalized_distance
	
	# Scale to min_damage_percent at edge
	return lerpf(min_damage_percent, 1.0, falloff)

func _apply_explosion_damage(target: Node, epicenter: Vector3, falloff: float):
	## Apply scaled damage, knockback, and hitstun to target
	var scaled_damage = explosion_damage * falloff
	var scaled_knockback = explosion_knockback * falloff
	var scaled_hitstun = explosion_hitstun * falloff
	
	# Calculate knockback direction (away from epicenter)
	var target_pos = target.global_position if target is Node3D else epicenter
	var kb_direction = (target_pos - epicenter).normalized()
	if kb_direction.length() < 0.1:
		kb_direction = Vector3.UP  # Straight up if at epicenter
	
	# Add upward component for better explosion feel
	kb_direction = (kb_direction + Vector3.UP * 0.5).normalized()
	
	if debug_projectile:
		print("[Grenade] Hitting %s: dmg=%.1f kb=%.1f hitstun=%.2f" % [target.name, scaled_damage, scaled_knockback, scaled_hitstun])
	
	# Check for multiplayer - send to server if client
	var network = get_node_or_null("/root/NetworkManager")
	if network and multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		# Client: Send hit request to server
		var target_id = target.get_instance_id()
		if target.has_method("get_network_id"):
			target_id = target.get_network_id()
		
		var hit_data = {
			"target_id": target_id,
			"target_name": target.name,
			"damage": scaled_damage,
			"damage_type": "explosive",
			"knockback_force": scaled_knockback,
			"knockback_direction": kb_direction,
			"hitstun_duration": scaled_hitstun,
			"hit_position": epicenter
		}
		network.request_projectile_hit(hit_data)
		return
	
	# Server or singleplayer: Apply directly
	if target.has_method("take_damage"):
		target.take_damage(scaled_damage, owner_entity, "explosive")
	
	if target.has_method("apply_knockback") and scaled_knockback > 0:
		target.apply_knockback(kb_direction * scaled_knockback)
	
	if target.has_method("apply_hitstun") and scaled_hitstun > 0:
		target.apply_hitstun(scaled_hitstun)

func _spawn_explosion_effect(pos: Vector3):
	## Spawn visual explosion effect
	if explosion_effect:
		var effect = explosion_effect.instantiate()
		get_tree().current_scene.add_child(effect)
		effect.global_position = pos
		# Scale effect to match explosion radius
		effect.scale = Vector3.ONE * (explosion_radius / 5.0)
	elif impact_effect:
		# Fallback to impact effect if no explosion effect set
		var effect = impact_effect.instantiate()
		get_tree().current_scene.add_child(effect)
		effect.global_position = pos
		effect.scale = Vector3.ONE * (explosion_radius / 3.0)

func _play_explosion_sound(pos: Vector3):
	## Play explosion sound
	var sound_path = explosion_sound if not explosion_sound.is_empty() else impact_sound
	if sound_path.is_empty():
		return
	
	var sound_manager = get_node_or_null("/root/SoundManager")
	if sound_manager and sound_manager.has_method("play_sound_3d_with_variation"):
		sound_manager.play_sound_3d_with_variation(sound_path + ".wav", pos, null, 3.0, 0.1)



