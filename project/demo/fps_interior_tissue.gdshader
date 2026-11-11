shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D detail_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_roughness : filter_linear_mipmap_anisotropic, repeat_enable;

uniform vec4 tissue_color : source_color = vec4(0.36, 0.12, 0.13, 1.0);
uniform float roughness_base : hint_range(0.0, 1.0) = 0.50;
uniform float specular_strength : hint_range(0.0, 1.0) = 0.36;
uniform float normal_strength : hint_range(0.0, 1.0) = 0.55;
uniform float color_detail_strength : hint_range(0.0, 1.0) = 0.36;
uniform vec2 detail_scale = vec2(5.5, 8.0);

varying float interior_weight;

void vertex() {
	interior_weight = COLOR.r;
}

void fragment() {
	vec2 detail_uv = UV * detail_scale;
	vec3 source_tissue = texture(detail_color, detail_uv).rgb;
	float tone = clamp((source_tissue.r - 0.07) * 7.2, -0.60, 0.67);
	float connective = max(source_tissue.g - source_tissue.r * 0.16, 0.0);
	vec3 dyed = tissue_color.rgb * (1.0 + tone * color_detail_strength);
	dyed += connective * color_detail_strength * vec3(0.39, 0.36, 0.27);

	// The outer few millimetres darken into the clot layer as each cap rises.
	float exposed = smoothstep(0.03, 0.70, interior_weight);
	vec3 edge = mix(vec3(0.041, 0.006, 0.008), dyed, 0.35);
	ALBEDO = mix(edge, dyed, exposed);
	float roughness_detail = texture(detail_roughness, detail_uv).r - 0.54;
	ROUGHNESS = clamp(roughness_base + roughness_detail * 0.52 - (1.0 - exposed) * 0.08, 0.27, 0.88);
	METALLIC = 0.0;
	SPECULAR = specular_strength;
	NORMAL_MAP = texture(detail_normal, detail_uv).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
}
