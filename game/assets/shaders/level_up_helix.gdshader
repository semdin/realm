shader_type spatial;
// The level-up moment's spirals (LevelUpFX): three comets of light winding up
// round the hero from the ground and meeting over the head, where the crown
// bursts. Each is a strip turned to the camera along a fixed helix; its head
// climbs the helix and the strip behind it is the comet's tail, a soft core
// in a wider glow that the erosion cloud flows through and eats into wisps
// toward the tail end (the bolts' energy_trail look), so it never reads as a
// drawn line.
//
// The mesh (LevelUpFX._helix_mesh) only carries the strip's parameters:
// UV.x along the helix (0 at the ground .. 1 over the head), UV.y across the
// strip (0..1), UV2.x the strand (0, 1, 2). One uniform drives it (`age`).
// Premultiplied: light added, with a little cover so it stays gold on a
// bright sky.
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform vec4 tint : source_color = vec4(1.0, 0.74, 0.32, 1.0);
uniform vec4 hot : source_color = vec4(1.0, 0.95, 0.82, 1.0);
uniform float age = 0.0;
uniform float launch = 0.08;      // seconds: the first comet leaves the ground
uniform float stagger = 0.06;    // seconds between the comets
uniform float climb = 1.25;      // seconds of a comet's run: its head reaches the crown a
                                 // little under half way, its tail then follows it out
uniform float tail = 0.5;        // the tail's length, as a share of the helix
uniform float turns = 1.6;
uniform float top = 2.35;        // metres: where the comets meet
uniform float foot_radius = 0.78;
uniform float crown_radius = 0.22;
uniform float width = 0.2;      // metres across the strip at the head

varying float v_d;       // 0 at the comet's head .. 1 at its tail end
varying float v_across;
varying float v_u;
varying float v_strand;

vec3 helix(float u, float strand) {
	float a = strand * 2.0943951 + u * turns * 6.2831853 + age * 0.6;
	float r = mix(foot_radius, crown_radius, smoothstep(0.0, 1.0, u));
	return vec3(cos(a) * r, u * top + 0.04, sin(a) * r);
}

void vertex() {
	float u = UV.x;
	float strand = UV2.x;
	float t = (age - launch - strand * stagger) / climb;
	// the head eases off the ground and slows as it reaches the crown
	float head = t <= 0.0 ? -1.0 : (1.0 + tail) * (1.0 - pow(1.0 - clamp(t, 0.0, 1.0), 1.7));
	v_d = (head - u) / tail;
	v_across = UV.y;
	v_u = u;
	v_strand = strand;
	vec3 here = helix(u, strand);
	vec3 ahead = helix(u + 0.01, strand);
	vec3 centre = (MODEL_MATRIX * vec4(here, 1.0)).xyz;
	vec3 along = normalize(mat3(MODEL_MATRIX) * (ahead - here));
	vec3 to_camera = normalize(CAMERA_POSITION_WORLD - centre);
	vec3 across = cross(along, to_camera);
	across = length(across) > 0.0001 ? normalize(across) : vec3(1.0, 0.0, 0.0);
	// thick at the head, thinning down the tail
	float w = width * mix(1.0, 0.45, clamp(v_d, 0.0, 1.0));
	vec3 world = centre + across * (UV.y - 0.5) * w * 2.0;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

void fragment() {
	if (v_d < -0.02 || v_d > 1.0) {
		discard;
	}
	float d = clamp(v_d, 0.0, 1.0);
	float x = v_across * 2.0 - 1.0;
	float n1 = texture(noise, vec2(v_u * 5.0 - age * 1.7 + v_strand * 0.31, v_across * 0.6 + v_strand * 0.17)).r;
	float n2 = texture(noise, vec2(v_u * 11.0 - age * 3.1 + v_strand * 0.53, v_across * 1.1 + 0.4)).r;
	float n = n1 * 0.62 + n2 * 0.38;
	float wobble = (n1 - 0.5) * 0.55 * (0.25 + d);
	float body = exp(-pow((x - wobble) * 2.3, 2.0));
	float core = exp(-pow((x - wobble) * 6.5, 2.0)) * (1.0 - d * 0.8);
	// the tail is eaten into wisps by the cloud
	float cut = smoothstep(d * 0.85 - 0.15, d * 0.85 + 0.2, n * (0.5 + body * 0.65));
	float fade = pow(1.0 - d, 1.3) * smoothstep(-0.02, 0.04, v_d);
	// the head burns brightest
	float head = exp(-d * 9.0);
	float light = (body * 0.65 + core * 1.0 + head * body * 1.0) * cut * fade;
	// the comets thin away as they reach the crown
	light *= 1.0 - smoothstep(0.86, 1.0, v_u) * 0.7;
	float heat = clamp(core * 0.8 + head * 0.6, 0.0, 1.0);
	vec3 colour = mix(tint.rgb, hot.rgb, heat);
	ALBEDO = colour * min(light, 1.0);
	ALPHA = clamp(light * 0.3, 0.0, 0.5);
}
