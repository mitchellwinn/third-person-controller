shader_type spatial;
render_mode unshaded;

// Terrain Multi-Layer Blending Shader
// Uses same shading logic as debug_texture.gdshader

group_uniforms height_blend;
uniform float height_blend_range : hint_range(0.1, 50.0) = 8.0;
uniform float height_blend_sharpness : hint_range(1.0, 20.0) = 1.0;
uniform float mid_height : hint_range(-100.0, 100.0) = 10.0;
uniform float high_height : hint_range(-100.0, 100.0) = 25.0;

group_uniforms slope_blend;
uniform float cliff_threshold : hint_range(0.0, 1.0) = 0.6;
uniform float cliff_blend_sharpness : hint_range(1.0, 50.0) = 6.67;

group_uniforms colors;
uniform vec3 color_low : source_color = vec3(0.25, 0.35, 0.15);
uniform vec3 color_mid : source_color = vec3(0.35, 0.3, 0.2);
uniform vec3 color_high : source_color = vec3(0.5, 0.48, 0.45);
uniform vec3 color_cliff : source_color = vec3(0.4, 0.38, 0.35);

group_uniforms shading;
uniform bool apply_normal_shading = true;
uniform float normal_shading_strength : hint_range(0.0, 1.0) = 0.745;

group_uniforms noise;
uniform float noise_scale : hint_range(0.001, 50.0) = 0.1;
uniform float noise_strength : hint_range(0.0, 1.0) = 0.15;
uniform int noise_octaves : hint_range(1, 8) = 3;
uniform float noise_lacunarity : hint_range(1.0, 4.0) = 2.0;
uniform float noise_persistence : hint_range(0.1, 1.0) = 0.5;

group_uniforms color_variation;
uniform float variation_amount : hint_range(0.0, 0.5) = 0.1;
uniform float variation_scale : hint_range(0.001, 50.0) = 0.3;
uniform float variation_sharpness : hint_range(1.0, 10.0) = 1.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// Simple hash noise
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise_single(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

// Fractal Brownian Motion - layered noise for more detail
float fbm(vec2 p, int octaves, float lacunarity, float persistence) {
	float value = 0.0;
	float amplitude = 1.0;
	float frequency = 1.0;
	float max_value = 0.0;

	for (int i = 0; i < octaves; i++) {
		value += amplitude * noise_single(p * frequency);
		max_value += amplitude;
		amplitude *= persistence;
		frequency *= lacunarity;
	}

	return value / max_value;
}

// Attempt sharper blend with power function
float sharp_blend(float t, float sharpness) {
	t = clamp(t, 0.0, 1.0);
	return pow(t, sharpness) / (pow(t, sharpness) + pow(1.0 - t, sharpness));
}

void fragment() {
	float height = world_pos.y;

	// Fractal noise for variation
	float n = fbm(world_pos.xz * noise_scale, noise_octaves, noise_lacunarity, noise_persistence);
	float height_offset = (n - 0.5) * 2.0 * noise_strength * height_blend_range;
	float adjusted_height = height + height_offset;

	// Height blends with sharpness control
	float blend_mid_raw = smoothstep(mid_height - height_blend_range * 0.5, mid_height + height_blend_range * 0.5, adjusted_height);
	float blend_high_raw = smoothstep(high_height - height_blend_range * 0.5, high_height + height_blend_range * 0.5, adjusted_height);

	float blend_mid = sharp_blend(blend_mid_raw, height_blend_sharpness);
	float blend_high = sharp_blend(blend_high_raw, height_blend_sharpness);

	// Cliff blend based on slope with sharpness
	float slope = world_normal.y;
	float cliff_raw = 1.0 - smoothstep(cliff_threshold - 0.15, cliff_threshold + 0.15, slope);
	float cliff_blend = sharp_blend(cliff_raw, cliff_blend_sharpness);

	// Blend height colors
	vec3 height_color = mix(color_low, color_mid, blend_mid);
	height_color = mix(height_color, color_high, blend_high);

	// Apply cliff
	vec3 base_color = mix(height_color, color_cliff, cliff_blend);

	// Add color variation with its own noise layer
	float var_noise = fbm(world_pos.xz * variation_scale, noise_octaves, noise_lacunarity, noise_persistence);
	var_noise = (var_noise - 0.5) * 2.0; // -1 to 1
	var_noise = sign(var_noise) * pow(abs(var_noise), 1.0 / variation_sharpness); // Sharpen
	base_color += vec3(var_noise * variation_amount);
	base_color = clamp(base_color, vec3(0.0), vec3(1.0));

	// Apply normal-based shading (same as debug_texture.gdshader)
	vec3 final_color = base_color;
	if (apply_normal_shading) {
		vec3 normal = normalize(NORMAL);
		// Simple directional shading (top-down light)
		float shading = dot(normal, vec3(0.0, 1.0, 0.0)) * 0.5 + 0.5;
		// Apply shading strength
		shading = mix(1.0, shading, normal_shading_strength);
		final_color *= shading;
	}

	ALBEDO = final_color;
}
