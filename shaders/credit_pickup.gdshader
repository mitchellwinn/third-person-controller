shader_type spatial;
render_mode unshaded;

// Credit pickup shader with animated color cycling for visual interest
uniform vec4 base_color : source_color = vec4(1.0, 0.85, 0.2, 1.0);  // Gold default
uniform float brightness : hint_range(0.5, 3.0) = 1.5;
uniform float shading_strength : hint_range(0.0, 1.0) = 0.6;
uniform float color_cycle_speed : hint_range(0.0, 5.0) = 1.5;  // Speed of color shift
uniform float color_cycle_amount : hint_range(0.0, 0.5) = 0.15;  // How much hue shifts

void fragment() {
    // Normal-based shading (top-down light)
    vec3 normal = normalize(NORMAL);
    float shading = dot(normal, vec3(0.0, 1.0, 0.0)) * 0.5 + 0.5;
    shading = mix(1.0, shading, shading_strength);

    // Animated color cycling - shift hue over time for sparkle effect
    vec3 color = base_color.rgb;
    float time_offset = TIME * color_cycle_speed;
    
    // Create subtle hue shift using sin waves on each channel
    color.r += sin(time_offset) * color_cycle_amount;
    color.g += sin(time_offset + 2.094) * color_cycle_amount;  // 120 degrees offset
    color.b += sin(time_offset + 4.189) * color_cycle_amount;  // 240 degrees offset
    
    // Add pulsing brightness
    float pulse = 1.0 + sin(time_offset * 2.0) * 0.1;
    
    ALBEDO = color * shading * brightness * pulse;
}
