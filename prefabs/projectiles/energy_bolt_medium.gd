extends ProjectileBase
class_name EnergyBoltMedium

## Medium energy projectile for assault rifles - balanced for sustained fire
## Low knockback and stun for continuous engagement without excessive disruption

func _on_projectile_ready():
	# AR rounds are moderate speed, designed for volume of fire
	speed = 140.0
	damage = 12.0
	damage_type = "energy_medium"
	lifetime = 2.5
	arm_time = 0.0  # Hit immediately
	
	# Very low knockback and stun - designed for sustained fire
	knockback_force = 0.5
	hitstun_duration = 0.02
	
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
		print("[EnergyBoltMedium] Hit %s at %s" % [body.name, hit_pos])

