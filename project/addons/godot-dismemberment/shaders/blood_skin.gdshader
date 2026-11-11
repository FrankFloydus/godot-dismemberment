shader_type spatial;
render_mode cull_disabled;
uniform vec4 base_color : source_color = vec4(0.65, 0.68, 0.72, 1.0);
// Unreal vector parameters are linear values. Keep this parameter linear;
// source_color would reinterpret the source's 0.005 as an sRGB input.
uniform vec4 blood_color = vec4(0.005, 0.0, 0.0, 1.0);
uniform float dismember_emissive = 5.0;
uniform sampler2D blood_noise : filter_linear_mipmap, repeat_enable;
uniform bool use_blood_noise = false;
uniform sampler2D base_texture : source_color, filter_linear_mipmap;
uniform bool use_base_texture = false;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool use_normal_texture = false;
uniform float normal_scale = 1.0;
uniform sampler2D roughness_texture : filter_linear_mipmap, repeat_enable;
uniform bool use_roughness_texture = false;
uniform int roughness_texture_channel = 0;
uniform sampler2D metallic_texture : filter_linear_mipmap, repeat_enable;
uniform bool use_metallic_texture = false;
uniform int metallic_texture_channel = 0;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform sampler2D ao_texture : filter_linear_mipmap, repeat_enable;
uniform bool use_ao_texture = false;
uniform bool enable_ao = false;
uniform int ao_texture_channel = 0;
uniform float ao_light_affect = 0.0;
uniform bool ao_on_uv2 = false;
uniform sampler2D orm_texture : filter_linear_mipmap, repeat_enable;
uniform bool use_orm_texture = false;
uniform vec3 uv1_scale = vec3(1.0);
uniform vec3 uv1_offset = vec3(0.0);
uniform vec3 uv2_scale = vec3(1.0);
uniform vec3 uv2_offset = vec3(0.0);
uniform bool texture_repeat = true;
uniform int cull_mode = 0;
uniform vec4 emission_color : source_color = vec4(0.0);
uniform sampler2D emission_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_emission_texture = false;
uniform bool emission_on_uv2 = false;
uniform bool emission_multiply = false;
uniform float emission_energy = 1.0;
uniform float blood_animation : hint_range(0.0, 1.0) = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.65;
uniform int blood_vertex_channel : hint_range(0, 3) = 2;
float fallback_noise(vec2 p) {
    return 0.5 + 0.17 * sin(p.x * 39.0 + sin(p.y * 27.0)) + 0.14 * sin(p.y * 53.0 + cos(p.x * 31.0));
}
float texture_channel(vec4 value, int channel) {
    if (channel == 4) return dot(value.rgb, vec3(0.333333333));
    return value[clamp(channel, 0, 3)];
}
vec2 material_uv(vec2 uv, vec3 scale, vec3 offset) {
    vec2 mapped = uv * scale.xy + offset.xy;
    return texture_repeat ? mapped : clamp(mapped, vec2(0.0), vec2(1.0));
}
void fragment() {
    if ((cull_mode == 0 && !FRONT_FACING) || (cull_mode == 1 && FRONT_FACING)) discard;
    // Reconstructed from MF_DIS_ApplyBlood / MF_DIS_BloodMask. The source uses
    // a custom primitive float; this port passes the same value as a uniform.
    float animation = clamp((blood_animation + 0.9) * ceil(blood_animation), 0.0, 1.0);
    float painted = COLOR[blood_vertex_channel] * animation;
    float noise = use_blood_noise ? texture(blood_noise, UV / 0.5).r : fallback_noise(UV / 0.5);
    float contrast_input = noise + pow(max(painted, 0.0), 50.0) * 10.0;
    float mask = clamp(contrast_input * 21.0 - 10.0, 0.0, 1.0) * painted;
    vec2 uv1 = material_uv(UV, uv1_scale, uv1_offset);
    vec2 uv2 = material_uv(UV2, uv2_scale, uv2_offset);
    vec4 base = base_color;
    if (use_base_texture) base *= texture(base_texture, uv1);
    vec3 orm = use_orm_texture ? texture(orm_texture, uv1).rgb : vec3(1.0);
    float original_roughness = use_orm_texture ? orm.g : roughness;
    if (use_roughness_texture) original_roughness *= texture_channel(texture(roughness_texture, uv1), roughness_texture_channel);
    float original_metallic = use_orm_texture ? orm.b : metallic;
    if (use_metallic_texture) original_metallic *= texture_channel(texture(metallic_texture, uv1), metallic_texture_channel);
    ALBEDO = mix(base.rgb, blood_color.rgb * dismember_emissive * 2.0, clamp(mask, 0.0, 1.0));
    ROUGHNESS = mix(original_roughness, 0.2 * (1.0 - mask), clamp(mask, 0.0, 1.0));
    METALLIC = original_metallic;
    SPECULAR = specular;
    AO = !enable_ao ? 1.0 : (use_ao_texture ? texture_channel(texture(ao_texture, ao_on_uv2 ? uv2 : uv1), ao_texture_channel) : orm.r);
    AO_LIGHT_AFFECT = ao_light_affect;
    vec3 tangent_normal = use_normal_texture ? texture(normal_texture, uv1).rgb : vec3(0.5, 0.5, 1.0);
    // MF_DIS_ApplyBlood preserves the incoming normal outside a wound and
    // blends it toward tangent-space +Z inside the blood mask.
    NORMAL_MAP = mix(tangent_normal, vec3(0.5, 0.5, 1.0), clamp(mask, 0.0, 1.0));
    NORMAL_MAP_DEPTH = normal_scale;
    vec3 emission_sample = use_emission_texture ? texture(emission_texture, emission_on_uv2 ? uv2 : uv1).rgb : vec3(0.0);
    EMISSION = (emission_multiply ? emission_color.rgb * emission_sample : emission_color.rgb + emission_sample) * emission_energy;
    // TRANSPARENCY_OUTPUT: native conversion inserts alpha only for transparent
    // source materials, so opaque characters keep the opaque render pipeline.
}
