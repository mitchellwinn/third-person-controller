extends Node
## Example usage of Pixel Impact Effect
## This shows how to integrate the effect with projectiles or other systems

# Example: How to use with existing projectiles
func example_projectile_impact_usage():
	"""
	# In your projectile script (like energy_bolt_small.gd), you would:

	@export var impact_effect_scene: PackedScene = preload("res://prefabs/effects/pixel_impact_effect.tscn")

	func _hit(target: Node):
		# ... existing hit logic ...

		# Spawn impact effect
		if impact_effect_scene:
			var effect = impact_effect_scene.instantiate()
			get_tree().current_scene.add_child(effect)
			effect.global_position = global_position

			# Optional: Customize the effect
			effect.effect_intensity = 1.5  # Make it more intense
			effect.lifetime = 0.3          # Shorter duration
			effect.pixel_scale = 12.0      # Higher resolution
			effect.expansion_rate = 3.0    # Expand faster
	"""

	pass

# Example: Manual effect spawning with different styles
func spawn_impact_effect(position: Vector3, style: String = "default"):
	var effect_scene = preload("res://prefabs/effects/pixel_impact_effect.tscn")
	var effect = effect_scene.instantiate()
	get_tree().current_scene.add_child(effect)
	effect.global_position = position

	# Get material reference for customization
	var material = effect.get_node("Sprite3D").material_override as ShaderMaterial

	match style:
		"explosion":
			material.set_shader_parameter("effect_intensity", 2.0)
			effect.lifetime = 0.8
			material.set_shader_parameter("expansion_rate", 1.5)
			material.set_shader_parameter("ring_count", 5.0)
			material.set_shader_parameter("sparkle_count", 12)
		"light_hit":
			material.set_shader_parameter("effect_intensity", 0.7)
			effect.lifetime = 0.3
			material.set_shader_parameter("expansion_rate", 3.0)
			material.set_shader_parameter("pixel_scale", 6.0)
			material.set_shader_parameter("sparkle_count", 4)
		"heavy_hit":
			material.set_shader_parameter("effect_intensity", 1.8)
			effect.lifetime = 0.6
			material.set_shader_parameter("expansion_rate", 1.8)
			material.set_shader_parameter("ring_count", 4.0)
			material.set_shader_parameter("noise_strength", 0.5)
		_:
			# Default style - already configured
			pass

# Example: Grenade explosion with multiple effects
func spawn_grenade_explosion(center_position: Vector3, radius: float = 3.0):
	var effect_scene = preload("res://prefabs/effects/pixel_impact_effect.tscn")

	# Main explosion effect
	var main_effect = effect_scene.instantiate()
	get_tree().current_scene.add_child(main_effect)
	main_effect.global_position = center_position
	main_effect.effect_intensity = 3.0
	main_effect.lifetime = 1.2
	main_effect.expansion_rate = 1.2
	main_effect.outer_radius = radius * 0.5
	main_effect.ring_count = 6.0
	main_effect.sparkle_count = 16

	# Spawn secondary effects around the explosion
	for i in range(6):
		var angle = (float(i) / 6.0) * TAU
		var offset = Vector3(cos(angle), 0, sin(angle)) * radius * 0.7
		var secondary_effect = effect_scene.instantiate()
		get_tree().current_scene.add_child(secondary_effect)
		secondary_effect.global_position = center_position + offset
		secondary_effect.effect_intensity = 1.2
		secondary_effect.lifetime = 0.4
		secondary_effect.expansion_rate = 4.0
		secondary_effect.pixel_scale = 4.0  # Lower resolution for secondary effects
