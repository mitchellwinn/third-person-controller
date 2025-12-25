shader_type spatial;
render_mode unshaded, cull_disabled;

// Global settings for debug texture
uniform float checker_size : hint_range(0.1, 10.0) = 1.0; // Size of each checker in world units
uniform vec3 color1 : source_color = vec3(0.2, 0.2, 0.2); // Dark color
uniform vec3 color2 : source_color = vec3(0.8, 0.8, 0.8); // Light color
uniform bool show_grid_lines = true;
uniform float grid_line_width : hint_range(0.0, 0.1) = 0.02;
uniform vec3 grid_line_color : source_color = vec3(0.0, 0.0, 0.0);
uniform bool apply_normal_shading = true;
uniform float normal_shading_strength : hint_range(0.0, 1.0) = 0.3;
uniform float triplanar_sharpness : hint_range(1.0, 32.0) = 16.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
    world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float get_checker(vec2 pos) {
    vec2 cell = floor(pos / checker_size);
    return mod(cell.x + cell.y, 2.0);
}

void fragment() {
    // Triplanar projection - project from 3 axes
    float checker_x = get_checker(world_pos.yz); // YZ plane (X-axis projection)
    float checker_y = get_checker(world_pos.xz); // XZ plane (Y-axis projection)
    float checker_z = get_checker(world_pos.xy); // XY plane (Z-axis projection)
    
    // Calculate blend weights based on world normal
    vec3 blend_weights = abs(world_normal);
    blend_weights = pow(blend_weights, vec3(triplanar_sharpness));
    blend_weights = blend_weights / (blend_weights.x + blend_weights.y + blend_weights.z);
    
    // Blend the checker patterns
    float checker = checker_x * blend_weights.x + checker_y * blend_weights.y + checker_z * blend_weights.z;
    checker = step(0.5, checker);
    
    // Base color
    vec3 base_color = mix(color1, color2, checker);
    
    // Apply normal-based shading to base colors
    vec3 final_color = base_color;
    if (apply_normal_shading) {
        vec3 normal = normalize(NORMAL);
        // Simple directional shading (top-down light)
        float shading = dot(normal, vec3(0.0, 1.0, 0.0)) * 0.5 + 0.5;
        
        // Apply shading strength
        shading = mix(1.0, shading, normal_shading_strength);
        final_color *= shading;
    }
    
    // Grid lines with triplanar
    float grid_line = 0.0;
    if (show_grid_lines) {
        vec2 grid_x = fract(world_pos.yz / checker_size);
        vec2 grid_y = fract(world_pos.xz / checker_size);
        vec2 grid_z = fract(world_pos.xy / checker_size);
        
        grid_x = min(grid_x, 1.0 - grid_x);
        grid_y = min(grid_y, 1.0 - grid_y);
        grid_z = min(grid_z, 1.0 - grid_z);
        
        float line_x = min(grid_x.x, grid_x.y) / grid_line_width;
        float line_y = min(grid_y.x, grid_y.y) / grid_line_width;
        float line_z = min(grid_z.x, grid_z.y) / grid_line_width;
        
        float gx = 1.0 - smoothstep(0.0, 1.0, line_x);
        float gy = 1.0 - smoothstep(0.0, 1.0, line_y);
        float gz = 1.0 - smoothstep(0.0, 1.0, line_z);
        
        grid_line = gx * blend_weights.x + gy * blend_weights.y + gz * blend_weights.z;
    }
    
    // Composite: base color -> grid lines
    final_color = mix(final_color, grid_line_color, grid_line);
    
    ALBEDO = final_color;
}
