shader_type spatial;
render_mode blend_mix, depth_draw_never, shadows_disabled, specular_schlick_ggx;

uniform sampler2D stain_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D tissue_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tissue_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tissue_roughness : filter_linear_mipmap_anisotropic, repeat_enable;

instance uniform vec4 stain_plane_0 : instance_index(0);
instance uniform vec4 stain_min_0 : instance_index(1);
instance uniform vec4 stain_max_0 : instance_index(2);
instance uniform vec4 stain_plane_1 : instance_index(3);
instance uniform vec4 stain_min_1 : instance_index(4);
instance uniform vec4 stain_max_1 : instance_index(5);
instance uniform vec4 stain_plane_2 : instance_index(6);
instance uniform vec4 stain_min_2 : instance_index(7);
instance uniform vec4 stain_max_2 : instance_index(8);
instance uniform vec4 stain_plane_3 : instance_index(9);
instance uniform vec4 stain_min_3 : instance_index(10);
instance uniform vec4 stain_max_3 : instance_index(11);

varying vec3 local_position;

void vertex() {
	local_position = VERTEX;
}

float stain(vec4 plane, vec4 low, vec4 high) {
	if (low.w == 0.0 || any(lessThan(local_position, low.xyz)) || any(greaterThan(local_position, high.xyz))) {
		return 0.0;
	}
	float signed_distance = dot(local_position, plane.xyz) - plane.w;
	float distance_to_cut = abs(signed_distance);
	if (distance_to_cut > 0.036) {
		return 0.0;
	}

	// Work in mesh coordinates so a moved fragment carries its original seam.
	vec3 seam = local_position - signed_distance * plane.xyz;
	vec2 along = vec2(seam.x * 13.0 + seam.y * 9.0, seam.z * 15.0 - seam.y * 6.0);
	float patches = texture(stain_noise, along).r;
	float breakup = texture(stain_noise, along * 3.8 + local_position.y * 2.1).r;
	float rivulets = texture(stain_noise, vec2((along.x + along.y * 0.63) * 0.85, along.y * 0.12)).r;
	float drip = smoothstep(0.50, 0.72, rivulets) * smoothstep(0.36, 0.62, patches);
	float downward = max(0.0, -sign(signed_distance) * plane.y);
	float width = 0.004 + 0.012 * smoothstep(0.27, 0.72, patches) + drip * (0.005 + 0.017 * downward);
	float edge = max(0.003, width + 0.005 * (breakup - 0.5));
	return 1.0 - smoothstep(width * 0.16, edge, distance_to_cut);
}

void fragment() {
	float opacity = max(stain(stain_plane_0, stain_min_0, stain_max_0), stain(stain_plane_1, stain_min_1, stain_max_1));
	opacity = max(opacity, stain(stain_plane_2, stain_min_2, stain_max_2));
	opacity = max(opacity, stain(stain_plane_3, stain_min_3, stain_max_3));
	if (opacity < 0.012) {
		discard;
	}

	vec2 tissue_uv = UV * 3.0;
	float wet_center = smoothstep(0.30, 0.92, opacity);
	vec3 detail = texture(tissue_color, tissue_uv).rgb;
	ALBEDO = mix(vec3(0.083, 0.008, 0.009), detail * vec3(0.68, 0.30, 0.30), wet_center);
	ROUGHNESS = mix(0.62, texture(tissue_roughness, tissue_uv).r, wet_center);
	SPECULAR = 0.50;

	// Turn the surface normal into the boundary where the layer thins out.
	vec2 bump = texture(tissue_normal, tissue_uv).xy * 2.0 - 1.0;
	bump *= mix(-1.6, 1.0, wet_center);
	NORMAL_MAP = vec3(clamp(0.5 + bump * 0.5, 0.0, 1.0), 1.0);
	NORMAL_MAP_DEPTH = opacity;
	ALPHA = opacity * 0.94;
}
