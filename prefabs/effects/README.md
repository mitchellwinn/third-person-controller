# Pixel Impact Effect

A billboarded 3D sprite effect that creates low-resolution pixel art-style impact animations, similar to effects in Super Smash Bros. 64.

## Features

- **Billboarded Sprite3D**: Always faces the camera for consistent visibility
- **Pixel Art Aesthetics**: Uses pixelation and noise for retro gaming feel
- **Animated Lifetime**: Smoothly animates from 0 to 1 over configurable duration
- **Radial Gradients**: Multiple expanding rings with configurable sharpness
- **Noise Texture**: Adds organic variation to the pixel art effect
- **Sparkle Effects**: Animated streaks that radiate outward
- **Highly Customizable**: Extensive shader parameters for different effect styles

## Usage

### Basic Usage

```gdscript
# Load the effect scene
var impact_effect = preload("res://prefabs/effects/pixel_impact_effect.tscn")

# Spawn at a position
var effect = impact_effect.instantiate()
get_tree().current_scene.add_child(effect)
effect.global_position = target_position
```

### Integration with Projectiles

Add to your projectile script:

```gdscript
@export var impact_effect_scene: PackedScene = preload("res://prefabs/effects/pixel_impact_effect.tscn")

func _hit(target: Node):
	# ... existing hit logic ...

	# Spawn impact effect
	if impact_effect_scene:
		var effect = impact_effect_scene.instantiate()
		get_tree().current_scene.add_child(effect)
		effect.global_position = global_position
```

### Customization

#### At Runtime (via Material)
```gdscript
var effect = impact_effect.instantiate()
var material = effect.get_node("Sprite3D").material_override as ShaderMaterial

# Adjust shader parameters directly on the material
material.set_shader_parameter("effect_intensity", 1.5)  # Brighter
material.set_shader_parameter("lifetime", 0.0)         # Reset animation
material.set_shader_parameter("pixel_scale", 12.0)     # Sharper pixels
material.set_shader_parameter("expansion_rate", 3.0)   # Expand faster
material.set_shader_parameter("ring_count", 5.0)       # More rings
material.set_shader_parameter("sparkle_count", 12)     # More sparkles
```

#### In Editor
Open the `.tscn` file and modify the embedded `ShaderMaterial_pixel_impact` subresource parameters directly in the scene.

### Preset Styles

```gdscript
# Light hit
effect.effect_intensity = 0.7
effect.lifetime = 0.3
effect.expansion_rate = 3.0
effect.pixel_scale = 6.0
effect.sparkle_count = 4

# Heavy hit
effect.effect_intensity = 1.8
effect.lifetime = 0.6
effect.expansion_rate = 1.8
effect.ring_count = 4.0
effect.noise_strength = 0.5

# Explosion
effect.effect_intensity = 2.0
effect.lifetime = 0.8
effect.expansion_rate = 1.5
effect.ring_count = 5.0
effect.sparkle_count = 12
```

## Shader Parameters

### Animation
- `lifetime`: Animation progress (0-1, controlled by script)
- `expansion_rate`: How the effect grows over time
- `fade_in_duration`: Time to fade in at start (as fraction of lifetime)
- `fade_out_duration`: Time to fade out at end (as fraction of lifetime)

### Visual
- `effect_intensity`: Overall brightness multiplier
- `base_color`: Base color (default white)
- `pixel_scale`: Pixel art resolution

### Radial Effects
- `inner_radius`: Starting radius of the effect
- `outer_radius`: Maximum radius the effect reaches
- `ring_count`: Number of concentric rings
- `ring_sharpness`: How sharp the ring edges are

### Noise & Texture
- `noise_strength`: How much noise affects the pattern
- `noise_scale`: Scale of the noise texture

### Sparkles
- `sparkle_count`: Number of radiating streaks
- `sparkle_length`: Length of each sparkle streak
- `sparkle_speed`: How fast sparkles animate

## Technical Details

- Uses a `Sprite3D` with billboard mode for consistent orientation
- Shader is spatial with `unshaded` and `cull_disabled` modes
- Alpha blending for transparency
- Automatic cleanup when animation finishes (configurable)
- Optimized with early discard for transparent pixels

## Technical Details

The effect uses embedded resources in the scene file:

- **Shader**: Embedded as a `Shader` subresource with all the pixel art effect logic
- **Material**: Embedded as a `ShaderMaterial` that applies the shader to the Sprite3D
- **Mesh**: A simple `QuadMesh` for the billboarded sprite
- **Script**: Simple GDScript that animates the `lifetime` shader parameter and auto-frees when done

### Modifying Shader Parameters

The shader parameters can be adjusted in two ways:

1. **At Runtime**: Access the material directly and set shader parameters
   ```gdscript
   var material = effect.get_node("Sprite3D").material_override as ShaderMaterial
   material.set_shader_parameter("effect_intensity", 1.5)
   ```

2. **In Editor**: Open the `.tscn` file and modify the embedded `ShaderMaterial_pixel_impact` parameters

### Creating Variations

To create different effect styles:

1. Duplicate the `.tscn` file
2. Modify the embedded `ShaderMaterial` parameters for different visuals
3. Adjust the `lifetime` property for different durations
4. Save as a new scene file for each effect type

## Files

- `pixel_impact_effect.tscn`: Main prefab scene (contains embedded shader and material)
- `pixel_impact_effect.gd`: Control script
- `../shaders/pixel_impact_effect.gdshader`: Original shader source (for reference)
