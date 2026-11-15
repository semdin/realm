// A falling rain drop (RealmWeather): a camera-facing upright quad drawn as a
// soft, tapered streak - a bright head, a tail that thins to nothing, edges
// that feather out - never a hard bar. Each drop has its own weight and
// brightness, and a drifting noise map thins and thickens the rain so it comes
// in gusts and sheets. Drops close to the lens fade so they never cross the
// screen as white bars.
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 tint : source_color = vec4(0.84, 0.89, 0.96, 0.85);
uniform sampler2D gust_noise : repeat_enable, filter_linear;
uniform float gust_scale = 0.018;
uniform vec2 gust_drift = vec2(0.035, 0.012);
uniform float near_fade = 2.0;
uniform float near_full = 6.5;
uniform float far_fade = 38.0;

varying float v_weight;
varying float v_gust;

float hash(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

void vertex() {
	// upright billboard: turns round the vertical axis only, keeps its scale
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz));
	vec3 forward = normalize(cross(right, vec3(0.0, 1.0, 0.0)));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(right, 0.0), vec4(0.0, 1.0, 0.0, 0.0), vec4(forward, 0.0), MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	v_weight = mix(0.45, 1.0, hash(float(INSTANCE_ID) + 0.37));
	vec2 at = MODEL_MATRIX[3].xz * gust_scale + TIME * gust_drift;
	float g = texture(gust_noise, at).r;
	v_gust = smoothstep(0.28, 0.72, g);
}

void fragment() {
	// UV.y 0 at the top (the tail), 1 at the bottom (the falling head)
	float along = UV.y;
	float tail = smoothstep(0.0, 0.75, along);
	float head = 1.0 - smoothstep(0.9, 1.0, along);
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	float edge = clamp(across * 1.4, 0.0, 1.0);
	float depth = -VERTEX.z;
	float lens = smoothstep(near_fade, near_full, depth);
	float far = 1.0 - smoothstep(far_fade * 0.6, far_fade, depth);
	float a = tint.a * tail * head * edge * lens * far * v_weight * mix(0.4, 1.0, v_gust);
	ALBEDO = tint.rgb * mix(0.85, 1.12, v_weight);
	ALPHA = a;
}
