shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

// The character screen's dais top (character_select.gd): light laid into the
// dark stone, no shapes of its own. A gold-lit groove runs round the rim in
// the house colour; the cloud map breaks it along its length so it glows in
// pools and fades in between, and it breathes slowly. A finer, dimmer groove
// sits inside it, hairline seams of the same light reach a little way in from
// the groove, and the overhead light leaves a soft warm pool where the
// character stands. The quad lies on the top face (3 x 3 m, centred), so UV
// distance from the centre is metres / 3.
// Replaced 2026-11-21: a flat emissive torus and rising spark spheres (the
// owner: "cheap glow and sparkle over the character").

uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_black;
uniform vec4 tint : source_color = vec4(1.0, 0.55, 0.2, 1.0);
uniform float strength = 1.0;
uniform float ring = 1.17;     // metres: the groove's radius
uniform float inner = 0.97;    // metres: the fine groove's radius

float band(float r, float at, float half_w, float soft) {
	return 1.0 - smoothstep(half_w, half_w + soft, abs(r - at));
}

void fragment() {
	vec2 p = (UV - 0.5) * 3.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	// the cloud map round the ring (two speeds against each other)
	vec2 polar = vec2(a / 6.2831853, r * 0.35);
	float n1 = texture(noise, polar * vec2(3.0, 1.0) + vec2(TIME * 0.006, 0.0)).r;
	float n2 = texture(noise, polar * vec2(7.0, 2.0) - vec2(TIME * 0.011, TIME * 0.003)).r;
	float pools = smoothstep(0.25, 0.85, n1 * 0.65 + n2 * 0.5);
	float breathe = 0.82 + 0.18 * sin(TIME * 0.7);
	// the groove: a hot core and light spilling to both sides
	float core = band(r, ring, 0.008, 0.01);
	float spill = exp(-abs(r - ring) / 0.045);
	float groove = (core * (0.4 + 0.6 * pools) + spill * 0.34 * pools) * breathe;
	// the fine inner groove, dimmer, steadier
	float fine = band(r, inner, 0.003, 0.006) * (0.30 + 0.25 * pools) + exp(-abs(r - inner) / 0.03) * 0.05;
	// seams: thin ridges of the cloud map in the band between the grooves
	float ridge = 1.0 - smoothstep(0.0, 0.035, abs(n2 - 0.5));
	float seam_zone = smoothstep(inner, inner + 0.05, r) * (1.0 - smoothstep(ring - 0.05, ring, r));
	float seams = ridge * seam_zone * pools * 0.22 * breathe;
	vec3 house = tint.rgb;
	vec3 hot = mix(house, vec3(1.0, 0.9, 0.7), 0.22);
	vec3 col = hot * core * (0.4 + 0.6 * pools) * breathe + house * (groove - core * (0.4 + 0.6 * pools) * breathe)
		+ house * (fine + seams);
	// the overhead light's warm pool under the feet
	float pool = exp(-r * r / 0.42) * 0.09;
	col += vec3(1.0, 0.92, 0.8) * pool;
	// the edge of the stone: nothing past the rim
	col *= 1.0 - smoothstep(1.3, 1.34, r);
	ALBEDO = col * strength;
}
