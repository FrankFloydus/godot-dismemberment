shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform vec4 trace_color : source_color = vec4(0.96, 0.84, 0.69, 0.45);
uniform float trace_age = 0.0;
uniform float trace_duration = 0.105;

varying flat float trace_length;

void vertex() {
	trace_length = INSTANCE_CUSTOM.x;
}

void fragment() {
	float distance_from_muzzle = (1.0 - UV.y) * trace_length;
	float end_fade = smoothstep(0.0, min(0.18, trace_length * 0.20), trace_length - distance_from_muzzle);
	float range_fade = 1.0 - smoothstep(12.0, 24.0, distance_from_muzzle);
	float age_fade = 1.0 - smoothstep(0.004, trace_duration, trace_age);
	float edge = abs(UV.x * 2.0 - 1.0);
	float core = 1.0 - smoothstep(0.04, 0.34, edge);
	float fringe = 1.0 - smoothstep(0.16, 1.0, edge);
	ALBEDO = trace_color.rgb;
	ALPHA = (0.48 * core + 0.17 * fringe) * end_fade * range_fade * age_fade * trace_color.a;
}
