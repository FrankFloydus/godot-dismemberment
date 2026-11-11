shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform sampler2D blood_texture : source_color, filter_linear;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform float dryness : hint_range(0.0, 1.0) = 0.0;
uniform float tile_size = 7.5;
uniform bool world_space_tiling = true;
uniform sampler2D noise_texture : filter_linear_mipmap, repeat_enable;
uniform bool use_noise_texture = false;
varying vec3 world_position;
void vertex() { world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
    vec4 pool = texture(blood_texture, UV);
    if (use_noise_texture) {
        vec2 noise_uv = world_space_tiling ? world_position.xz / max(0.001, tile_size) : UV;
        float noise = texture(noise_texture, noise_uv).r;
        pool.a *= clamp(noise * 21.0 - 10.0 + 0.8, 0.0, 1.0);
    }
    ALBEDO = pool.rgb;
    ALPHA = pool.a * opacity;
    ROUGHNESS = mix(0.12, 0.9, dryness);
    METALLIC = 0.5 * (1.0 - dryness);
}
