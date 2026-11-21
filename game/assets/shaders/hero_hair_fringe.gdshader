shader_type spatial;
// Hair cards, fringe pass (next_pass of hero_hair_card.gdshader): only the
// coverage the opaque pass cut away (below alpha_cut), blended over what is
// already drawn - soft strand ends and edges without TAA or MSAA. Close only
// (fringe_far): far away the cut edge is under a pixel anyway.
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
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
	if (coverage >= alpha_cut || coverage < 0.02 || -VERTEX.z > fringe_far) {
		discard;
	}
	NORMAL = n;
	ALBEDO = albedo;
	ROUGHNESS = 0.6;
	SPECULAR = 0.04;
	ALPHA = coverage / alpha_cut * 0.85;
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
