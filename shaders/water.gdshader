shader_type spatial;
render_mode blend_mix, cull_back, unshaded;

// Water texture strip used as animated base. Designed for both lakes and ocean water.
// The texture is assumed to be arranged in horizontal frames (hframes).
uniform sampler2D water_texture : source_color, repeat_enable, filter_nearest;
uniform int hframes = 5; // Number of horizontal frames in the water texture

// Controls how fast the frame strip loops (frames per second).
uniform float animation_speed : hint_range(0.0, 60.0) = 8.0;
// Controls how often the water movement/distortion updates (steps per second).
// Set to 0.0 to make movement smooth (continuous).
uniform float movement_update_rate : hint_range(0.0, 60.0) = 8.0;

// Secondary animated texture for variation at grazing angles (no white wash)
uniform bool enable_secondary_texture = false;
uniform sampler2D secondary_texture : source_color, repeat_enable, filter_nearest;
uniform int secondary_hframes = 5;
uniform float secondary_animation_speed : hint_range(0.0, 60.0) = 6.0;
uniform vec2 secondary_uv_scale = vec2(1.5, 1.5);
uniform vec2 secondary_uv_offset = vec2(0.0, 0.0);

// Noise texture for the secondary texture
uniform sampler2D secondary_noise : repeat_enable, filter_nearest;
uniform vec2 secondary_noise_scale = vec2(3.0, 3.0);
uniform float secondary_noise_speed : hint_range(-10.0, 10.0) = 0.5;
uniform float secondary_noise_strength : hint_range(0.0, 1.0) = 0.3;

// Angle-based blending control for secondary texture
uniform float secondary_angle_start : hint_range(0.0, 1.0) = 0.3; // Start fading in
uniform float secondary_angle_end : hint_range(0.0, 1.0) = 0.8; // Fully visible
uniform float secondary_blend_strength : hint_range(0.0, 1.0) = 0.5;

// UV tiling and offset so the water pattern can repeat seamlessly across large areas.
uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform vec2 uv_offset = vec2(0.0, 0.0);
uniform vec2 uv_scroll_speed = vec2(0.0, 0.0); // Continuous scrolling

// Oscillation for UV offset (to make the texture drift back and forth)
uniform vec2 uv_oscillation_amp = vec2(0.0, 0.0);
uniform vec2 uv_oscillation_freq = vec2(1.0, 1.0);
uniform vec2 uv_oscillation_speed = vec2(0.5, 0.5);

// Layered wave distortion. Adjust these to go from calm lake to choppy ocean.
uniform float wave_amplitude_1 : hint_range(0.0, 0.2) = 0.03;
uniform float wave_frequency_1 : hint_range(0.0, 40.0) = 12.0;
uniform float wave_speed_1 : hint_range(-10.0, 10.0) = 1.5;

uniform float wave_amplitude_2 : hint_range(0.0, 0.2) = 0.015;
uniform float wave_frequency_2 : hint_range(0.0, 40.0) = 20.0;
uniform float wave_speed_2 : hint_range(-10.0, 10.0) = -0.8;

uniform float small_ripple_amplitude : hint_range(0.0, 0.2) = 0.01;
uniform float small_ripple_frequency : hint_range(0.0, 80.0) = 40.0;
uniform float small_ripple_speed : hint_range(-10.0, 10.0) = 2.5;

// Edge / depth look: shallow at edges with white foam and more depth in the center.
// Foam width is in UV space (0-0.5 is reasonable).
uniform float foam_width : hint_range(0.0, 20.0) = 0.08;
uniform float foam_intensity : hint_range(0.0, 2.0) = 1.0;
// How much more transparent the water becomes at the foam edges.
uniform float edge_fade_strength : hint_range(0.0, 1.0) = 0.7;
// Overall opacity of the water surface.
uniform float water_opacity : hint_range(0.0, 1.0) = 0.85;

// Color tints: tweak these to switch between lake and ocean moods.
uniform vec4 shallow_tint : source_color = vec4(0.70, 0.90, 1.00, 1.0);
uniform vec4 deep_tint : source_color = vec4(0.05, 0.25, 0.75, 1.0);
// Depth (in meters) at which the water color fully transitions to deep_tint
uniform float color_deep_depth : hint_range(0.1, 10.0) = 3.0;
// Distance (in meters) over which water fades out at the very edge
uniform float shore_fade_distance : hint_range(0.0, 2.0) = 0.2;

// Opacity control for the white foam/highlights
uniform float foam_highlight_opacity : hint_range(0.0, 1.0) = 1.0;
// Cutoff for texture highlights (wave crests) - higher means fewer white crests
uniform float highlight_threshold : hint_range(0.0, 1.0) = 0.7;

// Foam noise: used to create crisp foam shapes at the shoreline.
uniform sampler2D foam_noise : repeat_enable, filter_nearest;
uniform vec2 foam_uv_scale = vec2(2.5, 2.5);
uniform float foam_noise_speed : hint_range(-10.0, 10.0) = 0.8;
uniform float foam_threshold : hint_range(0.0, 1.0) = 0.55;
uniform float foam_threshold_oscillation_amp : hint_range(0.0, 0.5) = 0.0; // Oscillation amplitude for foam threshold
uniform float foam_threshold_oscillation_freq : hint_range(0.0, 10.0) = 1.0; // Frequency of oscillation
// How much the noise distorts the shoreline (in meters).
uniform float foam_distortion : hint_range(0.0, 2.0) = 0.5;

// Depth Texture for real shoreline detection
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

// Rainbow iridescence on foam/white wash
uniform bool enable_iridescence = false;
uniform float iridescence_intensity : hint_range(0.0, 1.0) = 0.3;
uniform float iridescence_scale : hint_range(0.1, 10.0) = 2.0;
uniform float iridescence_speed : hint_range(0.0, 5.0) = 1.0;

// Screen-space refraction: wobble the background under the water.
uniform bool use_refraction = true;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
// Base strength of the refraction offset, in screen UV space.
uniform float refraction_strength : hint_range(0.0, 0.1) = 0.02;
// 0 = uniform refraction everywhere, 1 = much weaker refraction near edges (shallows).
uniform float refraction_depth_influence : hint_range(0.0, 1.0) = 0.7;

// Helper function for rainbow/iridescence effect
vec3 get_iridescence_color(float value) {
	// Create rainbow colors using sine waves offset by phase
	float r = sin(value * 6.28318) * 0.5 + 0.5;
	float g = sin(value * 6.28318 + 2.0944) * 0.5 + 0.5; // +120 degrees
	float b = sin(value * 6.28318 + 4.18879) * 0.5 + 0.5; // +240 degrees
	return vec3(r, g, b);
}

void fragment() {
	// Step the time for movement updates (global step for all movement)
	float time_used_for_movement = TIME;
	if (movement_update_rate > 0.0) {
		float update_rate_safe = max(movement_update_rate, 0.001);
		time_used_for_movement = floor(TIME * update_rate_safe) / update_rate_safe;
	}
	float stepped_time = time_used_for_movement;

	// Base UV calculation
	vec2 osc_offset = vec2(
		sin(stepped_time * uv_oscillation_speed.x) * uv_oscillation_amp.x,
		cos(stepped_time * uv_oscillation_speed.y) * uv_oscillation_amp.y
	);

	vec2 scroll_offset = uv_scroll_speed * stepped_time;

	// Apply all offsets
	vec2 base_uv = UV * uv_scale + uv_offset + scroll_offset + osc_offset;

	// --- Layered wave distortion -------------------------------------------------
	vec2 wave_uv = base_uv;

	// (stepped_time is now calculated above)

	// First large-scale wave layer.
	float wave1_x = sin(wave_uv.x * wave_frequency_1 + stepped_time * wave_speed_1);
	float wave1_y = cos(wave_uv.y * (wave_frequency_1 * 0.7) + stepped_time * (wave_speed_1 * 1.3));

	// Second, slightly different scale and direction.
	float wave2_x = sin((wave_uv.x + wave_uv.y) * wave_frequency_2 + stepped_time * wave_speed_2);
	float wave2_y = cos((wave_uv.x - wave_uv.y) * (wave_frequency_2 * 0.6) + stepped_time * (wave_speed_2 * 1.1));

	// Small ripples that add extra wobble.
	float ripple = sin((wave_uv.x + wave_uv.y) * small_ripple_frequency + stepped_time * small_ripple_speed);

	vec2 distortion = vec2(
		wave1_x * wave_amplitude_1 + wave2_x * wave_amplitude_2 + ripple * small_ripple_amplitude,
		wave1_y * wave_amplitude_1 + wave2_y * wave_amplitude_2 + ripple * small_ripple_amplitude
	);

	wave_uv += distortion;
	// Keep the water pattern seamlessly tiling.
	wave_uv = fract(wave_uv);

	// --- Strip animation (hframes) ----------------------------------------------
	int frames_i = max(hframes, 1);
	float frames = float(frames_i);

	// TIME * animation_speed = frames advanced per second.
	float frame_float = floor(mod(TIME * animation_speed, frames));

	vec2 anim_uv = wave_uv;
	anim_uv.x = (anim_uv.x + frame_float) / frames;

	vec4 water_tex = texture(water_texture, anim_uv);

	// --- Calculate view angle for later use -------------------------------------
	// Calculate view angle (dot product between view direction and surface normal)
	// VIEW is the direction from fragment to camera in view space
	vec3 view_dir = normalize(VIEW);
	vec3 normal = vec3(0.0, 0.0, 1.0); // Water surface faces up
	float view_dot = abs(dot(view_dir, normal));
	// view_dot: 1.0 = looking straight down, 0.0 = looking parallel to surface
	// We want secondary texture visible at low angles (parallel)
	float angle_factor = 1.0 - view_dot;

	// --- Secondary texture (angle-based) -----------------------------------------
	vec4 secondary_tex = vec4(0.0);
	if (enable_secondary_texture) {
		// Sample secondary texture with its own animation
		vec2 secondary_base_uv = UV * secondary_uv_scale + secondary_uv_offset + scroll_offset + osc_offset;

		// Apply noise distortion to secondary texture
		vec2 secondary_noise_uv = (UV * secondary_noise_scale + scroll_offset + osc_offset) + vec2(stepped_time * secondary_noise_speed, 0.0);
		float secondary_noise_val = texture(secondary_noise, secondary_noise_uv).r;
		float noise_offset_amount = (secondary_noise_val - 0.5) * secondary_noise_strength * 0.1;
		vec2 secondary_noise_offset = vec2(noise_offset_amount, noise_offset_amount);

		// Use noise to break up the angle blending edge
		// We mix the noise value into the angle factor to create a noisy transition
		// Modulate the threshold based on noise to make the cutoff irregular
		float noisy_angle_factor = clamp(angle_factor + (secondary_noise_val - 0.5) * 0.5, 0.0, 1.0);
		float secondary_mask = smoothstep(secondary_angle_start, secondary_angle_end, noisy_angle_factor);

		vec2 secondary_wave_uv = secondary_base_uv + distortion + secondary_noise_offset;
		secondary_wave_uv = fract(secondary_wave_uv);

		// Animate secondary texture
		int secondary_frames_i = max(secondary_hframes, 1);
		float secondary_frames = float(secondary_frames_i);
		float secondary_frame_float = floor(mod(TIME * secondary_animation_speed, secondary_frames));

		vec2 secondary_anim_uv = secondary_wave_uv;
		secondary_anim_uv.x = (secondary_anim_uv.x + secondary_frame_float) / secondary_frames;

		secondary_tex = texture(secondary_texture, secondary_anim_uv);

		// Blend secondary texture based on angle and strength
		water_tex = mix(water_tex, secondary_tex, secondary_mask * secondary_blend_strength);
	}

	// --- Depth / edge effects ----------------------------------------------------

	// Depth calculation fixed for Godot 4 Compatibility (OpenGL) renderer.
	// In OpenGL, NDC Z range is -1.0 to 1.0, while depth buffer is 0.0 to 1.0.
	// We need to remap depth to NDC before unprojecting.

	float depth_tex = texture(depth_texture, SCREEN_UV).r;

	// NOTE: If depth_texture is not working (e.g. Compatibility settings), this might return 1.0 or 0.0.

	// Remap 0..1 to -1..1 for OpenGL NDC
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth_tex * 2.0 - 1.0);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float linear_scene_depth = -view.z;

	// Same for surface depth (FRAGCOORD.z is 0..1 in window space)
	float z_depth = FRAGCOORD.z;
	vec3 ndc_surface = vec3(SCREEN_UV * 2.0 - 1.0, z_depth * 2.0 - 1.0);
	vec4 view_surface = INV_PROJECTION_MATRIX * vec4(ndc_surface, 1.0);
	view_surface.xyz /= view_surface.w;
	float linear_surface_depth = -view_surface.z;

	float depth_difference = linear_scene_depth - linear_surface_depth;

	// Safety clamp
	depth_difference = max(depth_difference, 0.0);

	// 0 near shore, 1 in deep water.
	// foam_width here acts as "foam depth range" in meters (approx).
	// If foam_width is 0.5, then 0.5m from shore is where foam ends.
	// We invert it: 1.0 at shore, 0.0 past foam_width.
	// Ensure smoothstep range is valid (foam_width > 0)
	float safe_foam_width = max(foam_width, 0.001);
	float shore_mask = 1.0 - smoothstep(0.0, safe_foam_width, depth_difference);

	// For color tinting, we use a deeper gradient.
	float deep_mask = smoothstep(0.0, color_deep_depth, depth_difference);
	vec3 depth_tint = mix(shallow_tint.rgb, deep_tint.rgb, deep_mask);

	// Apply tint to the water texture.
	vec3 tinted_water = water_tex.rgb * depth_tint;

	// Sample foam noise and create a crisp mask.
	// We use independent scale for noise (foam_uv_scale), but keep the global motion (offsets).
	vec2 noise_uv = (UV * foam_uv_scale + uv_offset + scroll_offset + osc_offset) + vec2(stepped_time * foam_noise_speed, 0.0);
	float noise_val = texture(foam_noise, noise_uv).r;

	// DEBUG: If you suspect noise isn't working, uncomment this to see raw noise.
	// ALBEDO = vec3(noise_val); ALPHA = 1.0; return;

	// To make foam "hug" the shore in a noisy way:
	// We modulate the effective foam width by the noise value.
	// This creates a shoreline that varies in distance from the geometry.

	// noise_val varies 0.0 to 1.0. We center it (-0.5 to 0.5).
	// foam_distortion controls how much this variation affects the width.
	// If distortion is 0.0, the width is constant (straight line).
	// If distortion is high, the width varies wildly.
	float width_variation = (noise_val - 0.5) * foam_distortion * 4.0;

	// The effective limit for foam at this pixel.
	// We clamp it to ensure it doesn't go negative.
	float effective_width = max(foam_width * (1.0 + width_variation), 0.0);

	// Check if current depth is within this variable width.
	// We multiply by foam_threshold as a global scaler if desired, or just use 1.0.
	// Let's use foam_threshold to gate the noise slightly?
	// Actually, let's just use effective_width directly vs depth.

	// Apply oscillation to foam threshold
	float oscillating_threshold = foam_threshold + sin(stepped_time * foam_threshold_oscillation_freq) * foam_threshold_oscillation_amp;

	float noise_mask = step(depth_difference, effective_width * oscillating_threshold);

	// Override: if depth is REALLY close to 0, force foam (shoreline glue).
	float hard_shore = step(depth_difference, 0.02); // 2cm hard shore line
	float final_foam = max(noise_mask, hard_shore) * water_tex.a;

	vec3 foam_col = vec3(1.0, 1.0, 1.0); // Pure white foam
	// Clamp mix factor to avoid invalid colors if intensity > 1.0
	vec3 water_with_foam = mix(tinted_water, foam_col, clamp(final_foam * foam_intensity, 0.0, 1.0));

	// --- Opacity Logic ---
	// We want the blue water to fade out near shore, but the foam and texture highlights (whitecaps) to stay visible.

	// 1. Opacity based on depth (fade out shallow water).
	float depth_fade = smoothstep(0.0, shore_fade_distance, depth_difference);

	// 2. Determine if the original texture pixel is "white" (a highlight/wave crest).
	// Simple brightness check: if it's bright, we treat it as foam/detail.
	float texture_brightness = dot(water_tex.rgb, vec3(0.299, 0.587, 0.114));

	// Use the adjustable highlight_threshold.
	// Using step for a clean, sharp pixel-art cutoff.
	// If brightness > threshold, it's a highlight (1.0).
	float texture_highlight = step(highlight_threshold, texture_brightness);

	// 3. Combine:
	// Base water alpha is controlled by depth_fade * water_opacity.
	// Highlights/Foam ignore depth_fade (or fade much less) so they pop near shore.
	float base_alpha = water_opacity * depth_fade;

	// If pixel is foam (from noise) OR highlight (from texture), keep it opaque.
	float foam_or_highlight = max(final_foam, texture_highlight);

	// Boost the whiteness of the highlights/foam.
	// We mix the current water color towards either white foam or secondary texture.
	// foam_highlight_opacity controls: 0 = secondary texture, 1 = white foam
	// At grazing angles, this effect is amplified (more secondary texture visible)
	vec3 water_final_rgb = water_with_foam;

	// At steep viewing angles (looking down), foam/highlights are white.
	// At grazing angles (looking parallel), foam/highlights blend with secondary texture.
	float foam_angle_blend = angle_factor; // 0 = looking down, 1 = parallel view

	if (enable_secondary_texture && foam_or_highlight > 0.1) {
		// Blend between white foam and secondary texture color
		vec3 white_foam = vec3(1.0, 1.0, 1.0);
		vec3 secondary_color = secondary_tex.rgb * depth_tint; // Apply same depth tint

		// foam_highlight_opacity controls the blend directly:
		// 0.0 = Pure Secondary Texture
		// 1.0 = Pure White Foam
		vec3 foam_color = mix(secondary_color, white_foam, foam_highlight_opacity);

		// If you want angle to *also* affect it (e.g. secondary texture only visible at angles),
		// we would multiply secondary_color visibility by angle_factor.
		// But based on your request, 0 should be "completely sampled from second texture".
		// So we just use the direct mix.

		float white_mix = clamp(foam_or_highlight * 0.8, 0.0, 1.0);
		water_final_rgb = mix(water_final_rgb, foam_color, white_mix);
	} else {
		// No secondary texture: just make foam white
		float white_mix = clamp(foam_or_highlight * 0.8, 0.0, 1.0);
		water_final_rgb = mix(water_final_rgb, vec3(1.0, 1.0, 1.0), white_mix);
	}

	// --- Rainbow iridescence on foam/white wash ---------------------------------
	if (enable_iridescence && foam_or_highlight > 0.1) {
		// Create iridescence pattern using UV and time
		float irid_pattern = (UV.x + UV.y) * iridescence_scale + TIME * iridescence_speed;
		vec3 rainbow_color = get_iridescence_color(irid_pattern);

		// Apply iridescence only to white areas (foam/highlights)
		float irid_mix = foam_or_highlight * iridescence_intensity;
		water_final_rgb = mix(water_final_rgb, water_final_rgb * rainbow_color * 1.5, irid_mix);
	}

	// Final alpha blends between the base transparency and full opacity for foam.
	// Foam is always opaque regardless of foam_highlight_opacity (which now controls color blend)
	float final_alpha_val = mix(base_alpha, 1.0, foam_or_highlight);

	// Ensure overall sprite alpha is respected
	final_alpha_val *= water_tex.a;

	if (use_refraction) {
		// Distort the screen UVs using the same wave distortion, scaled down.
		float depth_influence = deep_mask; // Use deep mask for refraction influence
		vec2 refract_offset = distortion * refraction_strength * depth_influence;

		vec2 screen_uv = SCREEN_UV + refract_offset;
		vec4 behind = textureLod(screen_texture, screen_uv, 0.0);

		// Mix between the refracted background and the water color.
		// Note: we use final_alpha_val to decide how much water color covers the background.
		vec3 final_rgb = mix(behind.rgb, water_final_rgb, final_alpha_val);

		// We output opaque here since we've already blended with the background.
		ALBEDO = final_rgb;
		ALPHA = 1.0;
	} else {
		// Classic transparent water, relying on regular alpha blending.
		ALBEDO = water_final_rgb;
		ALPHA = final_alpha_val;
	}
}
