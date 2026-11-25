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
	coverage *= edge_on_factor(VERTEX, VIEW);
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
}

void light() {
	hair_light(strand_dir, strand_ao, sparkle, strand_shift, NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, SPECULAR_AMOUNT, ALBEDO, DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
