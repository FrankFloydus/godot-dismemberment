shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform sampler2D splatter_mask : filter_linear_mipmap, repeat_disable;
uniform bool velocity_aligned = false;
uniform vec2 minimum_size_ratio = vec2(1.0);
uniform vec3 size_curve = vec3(0.2, 0.45, 1.0);
uniform float size_curve_tangent = 1.0;
uniform vec2 erosion_range = vec2(0.6);
uniform bool erosion_from_lifetime = false;
uniform float maximum_lifetime = 1.0;
uniform float thinness = 1.0;
uniform float softness = 0.01;
uniform float linear_red = 0.05;
varying float erosion;

// The exported Niagara size curves each have three cubic keys, with zero
// tangent at both endpoints and an authored tangent at the middle key.
float sprite_growth(float age) {
    float middle_time = size_curve.x;
    float middle_value = size_curve.y;
    if (age < middle_time) {
        float t = age / middle_time;
        return t * t * ((3.0 - 2.0 * t) * middle_value +
            (t - 1.0) * middle_time * size_curve_tangent);
    }
    float t = (age - middle_time) / (1.0 - middle_time);
    return mix(middle_value, size_curve.z, smoothstep(0.0, 1.0, t)) +
        t * (t - 1.0) * (t - 1.0) * (1.0 - middle_time) * size_curve_tangent;
}

void vertex() {
    // CPU particles store age and lifetime as fractions of the emitter lifetime.
    float lifetime_fraction = max(INSTANCE_CUSTOM.w, 0.00001);
    float age = clamp(INSTANCE_CUSTOM.y / lifetime_fraction, 0.0, 1.0);
    float roll = INSTANCE_CUSTOM.x;
    vec2 up = vec2(-sin(roll), cos(roll));
    vec2 sprite_size = mix(minimum_size_ratio, vec2(1.0), INSTANCE_CUSTOM.z);
    if (velocity_aligned) {
        vec2 projected_velocity = (VIEW_MATRIX * vec4(MODEL_MATRIX[1].xyz, 0.0)).xy;
        if (dot(projected_velocity, projected_velocity) > 0.000001) {
            up = normalize(projected_velocity);
        }
        erosion = 0.0;
    } else {
        sprite_size *= sprite_growth(age);
        float initial_erosion = mix(erosion_range.x, erosion_range.y, roll / TAU);
        if (erosion_from_lifetime) {
            initial_erosion *= maximum_lifetime * lifetime_fraction;
        }
        erosion = initial_erosion * (1.0 - smoothstep(0.0, 1.0, age));
    }

    vec2 right = vec2(up.y, -up.x);
    vec4 center = VIEW_MATRIX * MODEL_MATRIX[3];
    MODELVIEW_MATRIX = mat4(vec4(right * sprite_size.x, 0.0, 0.0),
        vec4(up * sprite_size.y, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), center);
}

void fragment() {
    if (velocity_aligned) {
        float distance_from_center = length(UV - vec2(0.5));
        float edge = max(fwidth(distance_from_center), 0.00001);
        ALPHA = 1.0 - smoothstep(0.5 - edge, 0.5 + edge, distance_from_center);
    } else {
        float mask = pow(texture(splatter_mask, UV).r, thinness);
        ALPHA = clamp((mask - (1.0 - erosion)) / max(softness, 0.00001), 0.0, 1.0);
    }
    float red = OUTPUT_IS_SRGB ? 1.055 * pow(linear_red, 1.0 / 2.4) - 0.055 : linear_red;
    ALBEDO = vec3(red, 0.0, 0.0);
}
