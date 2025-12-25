extends Node3D

## Test scene for pixel impact effect
## Press SPACE to spawn impact effects at random positions

@export var impact_effect_scene: PackedScene = preload("res://prefabs/effects/pixel_impact_effect.tscn")
@export var spawn_radius: float = 5.0
@export var spawn_height: float = 1.0

func _ready():
	print("Pixel Impact Effect Test Scene")
	print("Press SPACE to spawn impact effects")

func _input(event):
	if event.is_action_pressed("ui_accept"):  # Space bar
		spawn_random_impact()

func spawn_random_impact():
	if not impact_effect_scene:
		print("No impact effect scene assigned!")
		return

	# Spawn effect at random position around the scene
	var random_angle = randf() * TAU
	var random_distance = randf() * spawn_radius
	var spawn_pos = Vector3(
		cos(random_angle) * random_distance,
		spawn_height,
		sin(random_angle) * random_distance
	)

	var effect = impact_effect_scene.instantiate()
	add_child(effect)
	effect.global_position = spawn_pos

	print("Spawned impact effect at: ", spawn_pos)

# Example of how to spawn with custom parameters
func spawn_custom_impact(position: Vector3, intensity: float = 1.0, duration: float = 0.5):
	if not impact_effect_scene:
		return

	var effect = impact_effect_scene.instantiate()
	add_child(effect)
	effect.global_position = position
	effect.effect_intensity = intensity
	effect.lifetime = duration

	print("Spawned custom impact effect at: ", position, " intensity: ", intensity)


