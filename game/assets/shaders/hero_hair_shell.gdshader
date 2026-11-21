shader_type spatial;
// Short dense hair as shells (a full or short beard; tools/art/hero
// hair_cards.py "shells"): layers of the skin risen off it and slid along
// the combing, UV2.x the layer (0 at the skin .. 1 the outermost), COLOR.rgb
// the hair's direction (model space, 0.5-biased). shell_tex (head UV): R a
// random per strand, G the strand's length (as a share of the local
// height; 0 = no strand), B its core (1 at the strand's centre .. 0 at its
// edge). A layer shows the strands that reach it, thinner toward their
// tips; deeper layers lie in the beard's own shadow. Light: the hair cards'
// Kajiya-Kay along the combing direction.
render_mode cull_back;

#include "res://assets/shaders/hero_hair_card.gdshaderinc"
uniform sampler2D shell_tex : filter_linear_mipmap, hint_default_black;

void fragment() {
	float t = UV2.x;
	vec3 s = texture(shell_tex, UV).rgb;
	float len = s.g;
	// along the strand: 0 at its root .. 1 at its tip
	float along = t / max(len, 1e-3);
	// a strand tapers: the core it needs grows toward the tip
	float need = 0.12 + 0.7 * along * along;
	float lod = textureQueryLod(shell_tex, UV).x;
	float a = step(t, len) * smoothstep(need - 0.08, need + 0.08, s.b + max(lod, 0.0) * 0.12);
	ALPHA = a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	// per strand a shade, deeper in the beard darker, the tips lighter
	float shade = mix(0.62, 1.0, smoothstep(0.0, 0.8, t)) * mix(0.8, 1.15, s.r) * mix(0.92, 1.08, along);
	ALBEDO = min(hair_color * shade * darkness, vec3(0.8));
	ROUGHNESS = 0.6;
	SPECULAR = 0.04;
	// the include's vertex() sways cards only (use_card_data off here)
	strand_dir = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(COLOR.rgb * 2.0 - 1.0, 0.0)).xyz);
	strand_ao = mix(0.68, 1.0, t);
	sparkle = mix(0.4, 1.2, s.r);
	// a beard's hairs cross and curl: highlights break up strand by strand
	// (one shift for all drew a bright stripe down the chin)
	strand_shift = (s.r - 0.5) * 0.9;
	sparkle *= 0.55;
}

void light() {
	hair_light(strand_dir, strand_ao, sparkle, strand_shift, NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION,
		SPECULAR_AMOUNT, ALBEDO, DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
