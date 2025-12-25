extends ProjectileBase
class_name EnergyBoltSmall

## Small energy projectile for pistols - faster but weaker
## Extends ProjectileBase for all standard projectile functionality

func _on_projectile_ready():
	# Pistol bolts are fast but weaker
	speed = 120.0
	damage = 15.0
	damage_type = "energy_small"
	lifetime = 2.5
	arm_time = 0.0  # Hit immediately
	knockback_force = 2.0
	hitstun_duration = 0.1
	
	# No gravity, no bouncing
	use_gravity = false
	max_bounces = 0
	destroy_on_hit = true
	
	# Ensure collision mask includes enemies (layer 4)
	collision_mask_layers = 7  # Environment (1) + Players (2) + Enemies (4)
	
	# Debug off by default
	debug_projectile = false

func _on_hit(body: Node, hit_pos: Vector3, _hit_normal: Vector3):
	if debug_projectile:
		print("[EnergyBoltSmall] Hit %s at %s" % [body.name, hit_pos])

