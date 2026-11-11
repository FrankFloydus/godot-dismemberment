shader_type spatial;
render_mode unshaded, blend_add, cull_back, depth_draw_never, shadows_disabled, fog_disabled;

uniform float intensity : hint_range(0.0, 4.0, 0.05) = 1.0;
uniform float feather : hint_range(0.0, 1.0, 0.01) = 0.7;

varying float age;

void vertex() {
	age = INSTANCE_CUSTOM.y;
}

void fragment() {
	// Feather the curved shell and break its cooling tip into uneven wisps.
	float facing = max(dot(normalize(NORMAL), normalize(VIEW)), 0.0);
	float edge = pow(smoothstep(0.15, 0.90, facing), mix(1.0, 2.4, feather));
	float tip = 1.0 - smoothstep(0.40, 1.0, UV.y);
	float root = mix(0.73, 1.0, smoothstep(0.0, 0.15, UV.y));
	float angle = UV.x * TAU;
	float eddies = 0.51 + 0.24 * sin(UV.y * 46.0 - age * 3.0 + sin(angle * 3.0) * 2.2);
	eddies += 0.19 * sin(UV.y * 71.0 + age * 4.0 + angle * 5.0);
	float wisps = mix(1.0, smoothstep(0.16, 0.75, eddies), smoothstep(0.11, 0.72, UV.y));
	float bore_heat = 1.0 - smoothstep(0.12, 0.58, UV.y);
	vec3 temperature = mix(COLOR.rgb * vec3(1.0, 0.85, 0.68), mix(COLOR.rgb, vec3(1.0, 0.92, 0.73), 0.24), bore_heat);
	ALBEDO = temperature * intensity * mix(0.72, 1.26, bore_heat);
	ALPHA = COLOR.a * edge * tip * root * wisps;
}
