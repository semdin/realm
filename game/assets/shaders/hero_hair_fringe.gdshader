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
}

void light() {
	hair_light(strand_dir, strand_ao, sparkle, strand_shift, NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, SPECULAR_AMOUNT, ALBEDO, DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
