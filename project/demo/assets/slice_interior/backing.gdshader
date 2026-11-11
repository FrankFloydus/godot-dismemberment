shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D color_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roughness_map : filter_linear_mipmap_anisotropic, repeat_enable;

void fragment() {
	vec2 detail_uv = UV * 4.6;
	vec3 color_detail = texture(color_map, detail_uv).rgb;
	ALBEDO = vec3(0.034, 0.0065, 0.0090) + color_detail * 0.21;
	ROUGHNESS = clamp(0.25 + texture(roughness_map, detail_uv).r * 0.49, 0.42, 0.68);
	SPECULAR = 0.32;
	NORMAL_MAP = texture(normal_map, detail_uv).rgb;
	NORMAL_MAP_DEPTH = 0.35;
}
