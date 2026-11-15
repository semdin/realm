shader_type spatial;
// The waypoint's footprints (scripts/world/way_finder.gd), the old game's
// Marauder's-Map prints: one quad per print lying on the ground, UV.y = 0 at
// the toe. The prints from the player's feet along the next stretch of the
// route always show; INSTANCE_CUSTOM.x is how many steps ago a glow rippling
// forward passed this print (it brightens as the glow goes by), .y how far
// along the stretch it is (the far end fades out), .z its distance from the
// feet in steps (the nearest fade in). The ink is the erosion cloud (the
// spells' noise map) inside the print's shape, drifting a little, so no two
// prints are the same and none has a drawn edge.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 ink : source_color = vec4(1.0, 0.82, 0.42, 1.0);
uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform float trail = 4.0;        // prints the ripple lights at once
uniform float base = 0.5;         // brightness of a print the ripple is not on
uniform float opacity = 1.0;

varying vec3 step_info;
varying vec2 world_xz;

void vertex() {
	step_info = INSTANCE_CUSTOM.xyz;
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

float ellipse(vec2 p, vec2 c, vec2 r) {
	vec2 d = (p - c) / r;
	return 1.0 - smoothstep(0.55, 1.0, dot(d, d));
}

void fragment() {
	vec2 p = UV;
	// a shoe print: the sole and the heel, a gap between them
	float sole = ellipse(p, vec2(0.5, 0.32), vec2(0.36, 0.3));
	float heel = ellipse(p, vec2(0.5, 0.78), vec2(0.27, 0.19));
	float shape = max(sole, heel);
	// the ink: cloud noise in world metres, eating the print's edge
	float cloud = texture(noise, world_xz * 0.9 + vec2(TIME * 0.03, 0.0)).r;
	float fine = texture(noise, world_xz * 3.7 - vec2(0.0, TIME * 0.05)).r;
	// the shape holds; only its rim and a few flecks inside break up
	float ink_amount = smoothstep(0.2, 0.5, shape * (0.8 + 0.45 * cloud) + 0.18 * (fine - 0.5));
	float since = step_info.x;
	float glow = smoothstep(0.0, 0.6, since) * (1.0 - smoothstep(trail * 0.4, trail, since));
	float ends = smoothstep(0.2, 1.4, step_info.z) * (1.0 - smoothstep(0.7, 1.0, step_info.y));
	ALBEDO = ink.rgb * (1.1 + 0.35 * fine + 0.5 * glow);
	ALPHA = clamp(ink_amount * opacity * 0.9 * ends * mix(base, 1.0, glow), 0.0, 1.0);
}
