shader_type spatial;

uniform vec3 deck_color : source_color = vec3(0.15, 0.185, 0.225);
uniform float panel_size : hint_range(1.0, 4.0, 0.05) = 2.65;

varying vec2 deck_position;

void vertex() {
	deck_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 panel_grid = deck_position / panel_size + vec2(0.5);
	vec2 panel_id = floor(panel_grid);
	vec2 panel_uv = fract(panel_grid);
	vec2 panel_edge = min(panel_uv, 1.0 - panel_uv) * panel_size;
	vec2 pixel_span = max(fwidth(deck_position), vec2(0.001));
	float edge_distance = min(panel_edge.x, panel_edge.y);
	float edge_width = panel_edge.x < panel_edge.y ? pixel_span.x : pixel_span.y;

	// Width and coverage are in metres so the seams soften with distance.
	float seam = (1.0 - smoothstep(0.008, 0.015 + edge_width, edge_distance)) *
			min(1.0, 0.026 / edge_width);
	float edge_bevel = (1.0 - smoothstep(0.019, 0.045 + edge_width, edge_distance)) *
			min(1.0, 0.055 / edge_width) * (1.0 - seam);
	float panel_variation = fract(dot(panel_id, vec2(0.754878, 0.569840))) - 0.5;
	float grain = sin(dot(deck_position, vec2(160.0, 2.8))) *
			(1.0 - smoothstep(0.012, 0.025, pixel_span.x));

	// Each corner has the same recessed fastener and engraved slot.
	vec2 fastener_uv = panel_edge - vec2(0.105);
	float fastener_distance = length(fastener_uv);
	float detail_width = max(pixel_span.x, pixel_span.y);
	float detail_fade = 1.0 - smoothstep(0.018, 0.070, detail_width);
	float recess = (1.0 - smoothstep(0.025, 0.031 + detail_width, fastener_distance)) * detail_fade;
	float screw_head = (1.0 - smoothstep(0.017, 0.022 + detail_width, fastener_distance)) * detail_fade;
	float slot_distance = max(abs(fastener_uv.x) - 0.013, abs(fastener_uv.y) - 0.0025);
	float slot = (1.0 - smoothstep(0.0, detail_width, slot_distance)) * screw_head;

	vec3 deck = deck_color * (1.0 + panel_variation * 0.18 + grain * 0.012);
	deck = mix(deck, deck_color * 1.21, edge_bevel * 0.65);
	deck = mix(deck, deck_color * 0.42, seam);
	deck = mix(deck, deck_color * 0.45, recess);
	deck = mix(deck, deck_color * 1.45, screw_head * (1.0 - slot));
	ALBEDO = deck;
	METALLIC = 0.26;
	ROUGHNESS = mix(0.49, 0.38, screw_head);
}
