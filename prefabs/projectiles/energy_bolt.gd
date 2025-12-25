extends ProjectileBase
class_name EnergyBolt

## Energy projectile for rifles - fast, straight trajectory
## Extends ProjectileBase for all standard projectile functionality

func _on_projectile_ready():
	# Energy bolts are fast and straight
	speed = 150.0
	damage = 25.0
	damage_type = "energy"
	lifetime = 3.0
	arm_time = 0.0  # Hit immediately
	knockback_force = 3.0
	hitstun_duration = 0.15
	
	# No gravity, no bouncing
	use_gravity = false
	max_bounces = 0
	destroy_on_hit = true
	
	# Debug off by default
	debug_projectile = false

func _on_hit(body: Node, hit_pos: Vector3, _hit_normal: Vector3):
	if debug_projectile:
		print("[EnergyBolt] Hit %s at %s" % [body.name, hit_pos])

