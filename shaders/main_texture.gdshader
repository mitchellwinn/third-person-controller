shader_type spatial;
render_mode unshaded, cull_disabled;

// Texture
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform vec2 uv_offset = vec2(0.0, 0.0);

// Normal-based shading (fake lighting without actual lights)
uniform bool apply_normal_shading = true;
uniform float normal_shading_strength : hint_range(0.0, 1.0) = 0.5;
uniform vec3 light_direction = vec3(0.0, 1.0, 0.0); // Default: top-down
uniform float ambient_light : hint_range(0.0, 1.0) = 0.3;

void fragment() {
    // Sample texture with UV scaling and offset
    vec2 uv = UV * uv_scale + uv_offset;
    vec4 tex_color = texture(albedo_texture, uv) * albedo_tint;

    vec3 final_color = tex_color.rgb;

    // Apply normal-based shading
    if (apply_normal_shading) {
        vec3 normal = normalize(NORMAL);
        vec3 light_dir = normalize(light_direction);

        // Dot product for directional shading
        float ndotl = dot(normal, light_dir) * 0.5 + 0.5; // Remap -1..1 to 0..1

        // Mix between ambient and full light based on normal
        float shading = mix(ambient_light, 1.0, ndotl);

        // Apply shading strength
        shading = mix(1.0, shading, normal_shading_strength);
        final_color *= shading;
    }

    ALBEDO = final_color;
}
