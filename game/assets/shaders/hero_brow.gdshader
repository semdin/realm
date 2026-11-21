shader_type spatial;
// Hero eyebrows (MPFB alpha cards): the hair colour and the card's alpha, cut
// by scissor so they never enter the transparent sort.
render_mode cull_disabled;

#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;

void fragment() {
	// the card's colour is not trusted (its transparent texels carry light
	// colour into the mips): the shape comes from alpha, the colour is the hair's
	ALBEDO = hair_color * 0.8;
	ALPHA = texture(albedo_tex, UV).a;
	ALPHA_SCISSOR_THRESHOLD = 0.4;
	ROUGHNESS = 0.8;
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
