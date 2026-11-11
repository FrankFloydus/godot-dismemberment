shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform bool strike_flash = false;

void vertex() {
	vec3 center = MODEL_MATRIX[3].xyz;
	vec3 long_axis = MODEL_MATRIX[1].xyz;
	vec3 across = cross(long_axis, CAMERA_POSITION_WORLD - center);
	if (strike_flash) {
		long_axis = INV_VIEW_MATRIX[1].xyz * length(long_axis);
		across = INV_VIEW_MATRIX[0].xyz;
	} else if (dot(across, across) < 0.000001) {
		across = INV_VIEW_MATRIX[0].xyz;
	}
	across = normalize(across) * length(MODEL_MATRIX[0].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(across, 0.0), vec4(long_axis, 0.0),
		vec4(normalize(cross(across, long_axis)), 0.0), vec4(center, 1.0));
}

void fragment() {
	float shape;
	if (strike_flash) {
		vec2 point = UV * 2.0 - 1.0;
		float core = 1.0 - smoothstep(0.03, 0.37, length(point));
		float horizontal = (1.0 - smoothstep(0.02, 0.21, abs(point.y)))
			* (1.0 - smoothstep(0.04, 1.0, abs(point.x)));
		float vertical = (1.0 - smoothstep(0.01, 0.10, abs(point.x)))
			* (1.0 - smoothstep(0.05, 0.72, abs(point.y)));
		shape = max(core, max(horizontal, vertical) * 0.57);
	} else {
		float lengthwise = 1.0 - UV.y;
		float width = mix(0.10, 1.0, lengthwise);
		float across = abs(UV.x * 2.0 - 1.0) / width;
		float core = 1.0 - smoothstep(0.13, 0.56, across);
		float edge = 1.0 - smoothstep(0.35, 1.0, across);
		float tail = smoothstep(0.0, 0.76, lengthwise);
		float tip = 1.0 - smoothstep(0.91, 1.0, lengthwise);
		shape = mix(edge, core, 0.72) * tail * tip;
	}
	ALBEDO = COLOR.rgb * 1.25;
	ALPHA = COLOR.a * shape;
}
