shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// Simple radial impact effect
uniform float lifetime : hint_range(0.0, 1.0) = 0.0;
uniform float effect_intensity : hint_range(0.0, 3.0) = 1.5;
uniform vec3 base_color : source_color = vec3(1.0, 0.8, 0.2);
uniform float inner_radius : hint_range(0.0, 1.0) = 0.2;
uniform float outer_radius : hint_range(0.0, 1.0) = 0.8;

// Unused but kept for compatibility with existing scenes
uniform float pixel_scale = 10.0;
uniform float expansion_rate = 2.0;
uniform float fade_in_duration = 0.1;
uniform float fade_out_duration = 0.5;
uniform float noise_strength = 0.3;
uniform float noise_scale = 10.0;
uniform float ring_count = 2.0;
uniform float ring_sharpness = 0.5;
uniform float sparkle_count = 6.0;
uniform float sparkle_length = 0.3;
uniform float sparkle_speed = 1.0;

void vertex() {
    // Manual billboarding that handles edge cases better than Sprite3D billboard mode
    vec3 cam_right = normalize(vec3(VIEW_MATRIX[0][0], VIEW_MATRIX[1][0], VIEW_MATRIX[2][0]));
    vec3 cam_up = normalize(vec3(VIEW_MATRIX[0][1], VIEW_MATRIX[1][1], VIEW_MATRIX[2][1]));
    
    // Apply billboard transformation
    vec3 billboard_pos = cam_right * VERTEX.x + cam_up * VERTEX.y;
    VERTEX = billboard_pos;
}

void fragment() {
    // Pixelate UV coordinates
    vec2 uv = UV;
    uv = floor(uv * pixel_scale) / pixel_scale;
    uv = uv - 0.5;
    
    float dist = length(uv) * 2.0;
    
    // Expand over time
    float expand = lifetime * expansion_rate;
    float adjusted_dist = dist - expand * 0.5;
    
    // Ring effect
    float ring_inner = inner_radius + expand * 0.3;
    float ring_outer = outer_radius + expand * 0.5;
    float ring = smoothstep(ring_inner, ring_inner + 0.1, adjusted_dist) * 
                 smoothstep(ring_outer + 0.1, ring_outer, adjusted_dist);
    
    // Core glow
    float core = 1.0 - smoothstep(0.0, inner_radius + expand * 0.2, adjusted_dist);
    
    // Combine
    float effect = (core + ring * 0.8) * effect_intensity;
    
    // Fade out over lifetime
    float fade = 1.0 - smoothstep(0.5, 1.0, lifetime);
    effect *= fade;
    
    // Final color with orange-yellow gradient
    vec3 color = mix(vec3(1.0, 1.0, 0.8), base_color, adjusted_dist);
    
    ALBEDO = color * effect;
    ALPHA = clamp(effect, 0.0, 1.0);
    
    // Discard fully transparent pixels
    if (ALPHA < 0.01) {
        discard;
    }
}
