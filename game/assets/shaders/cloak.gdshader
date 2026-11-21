shader_type spatial;
// The hero cloak (art/cloaks/scripts/build_cloak_sim.py): a plain two-sided
// fabric. It moves by its skin alone - the collar and mantle ride the torso,
// the panel rides the Cloak_* chain bones CloakDeformer swings with a
// SpringBoneSimulator3D (scripts/entities/cloak_deformer.gd).
render_mode cull_disabled;
// rising from a death (HeroView.ghost): 0 solid .. 1 gone
instance uniform float ghost = 0.0;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform float rim : hint_range(0.0, 1.0) = 0.3;
uniform float rim_tint : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	ALBEDO = c.rgb;
	ROUGHNESS = roughness;
	RIM = rim;
	RIM_TINT = rim_tint;
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
