shader_type spatial;
// Hair cards, opaque pass: coverage cut at alpha_cut, writes depth and casts
// strand-shaped shadows. Its next_pass (hero_hair_fringe.gdshader) blends
// the thin coverage this pass cuts away. See hero_hair_card.gdshaderinc.
render_mode cull_disabled;
#include "res://assets/shaders/hero_hair_card.gdshaderinc"

void fragment() {
	vec3 albedo;
	float coverage;
	float ao;
	float glint;
	float jitter;
	vec3 n = FRONT_FACING ? NORMAL : -NORMAL;
	hair_surface(UV, UV2, COLOR, albedo, coverage, ao, glint, jitter);
	strand_dir = normalize(strand_along_u ? TANGENT : BINORMAL);
	strand_ao = ao;
	sparkle = glint;
	strand_shift = jitter;
	NORMAL = n;
	ALBEDO = albedo;
	ROUGHNESS = 0.6;
	// the strand lobes are the specular; the sky's reflection would grey it
	SPECULAR = 0.04;
	ALPHA = coverage;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	// rising from a death (HeroView.ghost): a share of the pixels left out in
	// a fine dither (no blending: the opaque pass, no sorting), the rest pale
	// and lit from within, brightest at the rim
	if (ghost > 0.0) {
		float grain = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		if (grain < ghost) {
			discard;
		}
		float edge = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
		ALBEDO = mix(ALBEDO, vec3(0.5, 0.68, 0.95), ghost * 0.7);
		EMISSION += vec3(0.32, 0.55, 1.0) * (0.18 + edge * 1.3) * ghost;
	}
}

void light() {
	hair_light(strand_dir, strand_ao, sparkle, strand_shift, NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, SPECULAR_AMOUNT, ALBEDO, DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
