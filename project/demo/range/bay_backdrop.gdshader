shader_type spatial;

// A recessed instrument panel with fixed measurement marks. Each bay has
// its own accent and the backdrop remains readable under dynamic lights.
uniform vec4 accent : source_color = vec4(0.25, 0.84, 0.90, 1.0);
uniform vec4 panel_color : source_color = vec4(0.115, 0.159, 0.195, 1.0);

float line_at(float value, float center, float half_width) {
	float filter_width = max(fwidth(value), 0.001);
	return 1.0 - smoothstep(half_width, half_width + filter_width, abs(value - center));
}

void fragment() {
	vec2 p = UV;
	vec2 side = min(p, 1.0 - p);
	float border = line_at(side.x, 0.085, 0.002) + line_at(side.y, 0.098, 0.0014);
	float side_rail = (1.0 - smoothstep(0.082, 0.091, side.x)) * smoothstep(0.14, 0.2, side.y);
	float tick = line_at(fract(p.y * 19.0), 0.5, 0.024) * side_rail;
	float frame = line_at(side.x, 0.016, 0.0025) + line_at(side.y, 0.018, 0.0018);
	float bottom = 1.0 - smoothstep(0.092, 0.28, p.y);
	float radial = 1.0 - smoothstep(0.08, 0.65, length((p - vec2(0.5, 0.44)) * vec2(1.0, 0.72)));
	vec3 color = panel_color.rgb * (0.82 + 0.48 * radial);
	color *= 1.0 - 0.22 * bottom;
	ALBEDO = mix(color, accent.rgb * 0.35, clamp(tick * 0.78 + border * 0.32, 0.0, 1.0));
	EMISSION = accent.rgb * (tick * 0.055 + frame * 0.026 + radial * 0.010);
	METALLIC = 0.16;
	ROUGHNESS = 0.69;
}
