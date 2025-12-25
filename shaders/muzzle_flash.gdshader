shader_type spatial;
render_mode unshaded, cull_disabled;

// Muzzle Flash Shader - Explosive, quick, and flashy
uniform float lifetime : hint_range(0.0, 1.0) = 0.0; // Animation progress from 0 to 1
uniform float effect_intensity : hint_range(1.0, 10.0) = 5.0;
uniform vec3 flash_color : source_color = vec3(1.0, 0.9, 0.6); // Bright yellowish-white
uniform vec3 core_color : source_color = vec3(1.0, 0.7, 0.3); // Orange core
uniform float pixel_scale : hint_range(1.0, 30.0) = 20.0; // High pixel density for crisp look

// Flash characteristics
uniform float expansion_speed : hint_range(5.0, 50.0) = 25.0;
uniform float core_size : hint_range(0.01, 0.5) = 0.1;
uniform float flash_radius : hint_range(0.1, 2.0) = 0.8;
uniform float flash_sharpness : hint_range(1.0, 20.0) = 8.0;

// Lens flare effects
uniform int flare_rays : hint_range(3, 16) = 8;
uniform float flare_length : hint_range(0.1, 2.0) = 0.6;
uniform float flare_intensity : hint_range(0.0, 2.0) = 0.8;

// Spark effects
uniform int spark_count : hint_range(0, 20) = 12;
uniform float spark_size : hint_range(0.01, 0.1) = 0.03;
uniform float spark_speed : hint_range(1.0, 20.0) = 8.0;

varying vec2 uv_coords;

void vertex() {
    uv_coords = UV;

    // Manual billboarding that handles edge cases better than Sprite3D billboard mode
    // Get camera right and up vectors in world space
    vec3 cam_right = normalize(vec3(VIEW_MATRIX[0][0], VIEW_MATRIX[1][0], VIEW_MATRIX[2][0]));
    vec3 cam_up = normalize(vec3(VIEW_MATRIX[0][1], VIEW_MATRIX[1][1], VIEW_MATRIX[2][1]));

    // Apply billboard transformation - scale vertex position by camera orientation
    vec3 billboard_pos = cam_right * VERTEX.x + cam_up * VERTEX.y;
    VERTEX = billboard_pos;
}

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 pixelate_uv(vec2 uv, float scale) {
    return floor(uv * scale) / scale;
}

// Create explosive core
float create_core(vec2 uv, float time) {
    float dist = length(uv);
    float core = 1.0 - smoothstep(0.0, core_size * (1.0 + time * 2.0), dist);
    return pow(core, 2.0); // Sharper falloff
}

// Create expanding flash ring
float create_flash_ring(vec2 uv, float time) {
    float dist = length(uv);
    float expansion = time * expansion_speed;
    float ring_width = 0.1;
    float ring_center = expansion;
    float ring = 1.0 - smoothstep(ring_center - ring_width, ring_center + ring_width, dist);
    ring *= 1.0 - smoothstep(ring_center + ring_width, flash_radius, dist);
    return pow(ring, flash_sharpness);
}

// Create lens flare rays
float create_lens_flare(vec2 uv, float time) {
    float flare = 0.0;
    float angle_step = 6.28318 / float(flare_rays);

    for(int i = 0; i < flare_rays; i++) {
        float angle = float(i) * angle_step;
        vec2 ray_dir = vec2(cos(angle), sin(angle));
        float ray_proj = dot(uv, ray_dir);

        if(ray_proj > 0.0) {
            float dist_from_center = length(uv - ray_proj * ray_dir);
            float ray_intensity = 1.0 - smoothstep(0.0, flare_length, abs(ray_proj));
            ray_intensity *= 1.0 - smoothstep(0.0, 0.05, dist_from_center);
            flare += ray_intensity;
        }
    }

    return flare * flare_intensity * (1.0 - time * 0.5);
}

// Create explosive sparks
float create_sparks(vec2 uv, float time) {
    float spark_effect = 0.0;

    for(int i = 0; i < spark_count; i++) {
        // Create deterministic spark positions
        vec2 spark_seed1 = vec2(float(i) * 0.618, float(i) * 0.382);
        vec2 spark_seed2 = vec2(float(i) * 0.382, float(i) * 0.618);
        vec2 spark_pos = vec2(hash(spark_seed1) * 2.0 - 1.0, hash(spark_seed2) * 2.0 - 1.0) * 0.5;
        vec2 spark_dir = normalize(spark_pos);

        // Animate spark outward
        float spark_dist = length(spark_pos) + time * spark_speed;
        vec2 spark_world_pos = spark_dir * spark_dist;

        float dist_to_spark = length(uv - spark_world_pos);
        float spark = 1.0 - smoothstep(0.0, spark_size, dist_to_spark);
        spark *= 1.0 - smoothstep(0.0, flash_radius, spark_dist); // Fade at edge

        spark_effect += spark;
    }

    return spark_effect * (1.0 - time);
}

void fragment() {
    // Pixelate for crisp look
    vec2 pixel_uv = pixelate_uv(uv_coords, pixel_scale);
    vec2 centered_uv = pixel_uv - 0.5;

    // Animation curves - muzzle flashes are very quick
    float expand_progress = pow(lifetime, 0.3); // Faster initial expansion
    float flash_intensity = 1.0 - pow(lifetime, 0.5); // Quick fade
    float overall_alpha = flash_intensity * effect_intensity;

    // Create flash components
    float core = create_core(centered_uv, expand_progress);
    float flash_ring = create_flash_ring(centered_uv, expand_progress);
    float lens_flare = create_lens_flare(centered_uv, lifetime);
    float sparks = create_sparks(centered_uv, expand_progress);

    // Combine effects
    float combined_effect = core + flash_ring + lens_flare + sparks;

    // Color mixing - core is hotter (more orange), outer flash is brighter (more white)
    vec3 final_color = mix(core_color, flash_color, flash_ring + lens_flare);
    final_color = mix(final_color, vec3(1.0, 1.0, 1.0), sparks * 0.5); // Sparks add white highlights

    // Apply intensity and alpha
    ALBEDO = final_color * combined_effect * overall_alpha;
    ALPHA = combined_effect * overall_alpha;

    // Early discard for performance
    if (ALPHA < 0.01) {
        discard;
    }

    // Add some emissive glow
    EMISSION = final_color * combined_effect * overall_alpha * 2.0;
}
