shader_type spatial;
// The hero's eyeballs (Face_Eyeball, tools/art/hero/build_head.py): the
// MakeHuman eye texture (two eyeball discs, CC0) with the iris re-coloured to
// the look's eye colour (its shading kept: luminance over ref_luma), a
// darker limbal ring, and the lids' shadow baked per vertex (COLOR.r: the eyes
// never turn, so it stays true). The wet shine is the cornea's
// (hero_face_cornea.gdshader).

#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D eye_tex : source_color, filter_linear_mipmap_anisotropic;
// the two iris centres in Godot's UV (v down; eye.png measured)
uniform vec2 iris_a = vec2(0.708, 0.297);
uniform vec2 iris_b = vec2(0.291, 0.710);
uniform float iris_radius = 0.115;
uniform float pupil_radius = 0.042;
uniform float ref_luma = 0.11;

void fragment() {
	vec3 t = texture(eye_tex, UV).rgb;
	vec2 c = distance(UV, iris_a) < distance(UV, iris_b) ? iris_a : iris_b;
	float r = distance(UV, c);
	float iris = 1.0 - smoothstep(iris_radius - 0.012, iris_radius, r);
	float pupil = 1.0 - smoothstep(pupil_radius - 0.004, pupil_radius + 0.004, r);
	float lum = dot(t, vec3(0.299, 0.587, 0.114));
	vec3 iris_col = iris_color * clamp(lum / ref_luma, 0.35, 1.9);
	iris_col *= mix(0.45, 1.0, smoothstep(iris_radius, iris_radius - 0.035, r));
	vec3 col = mix(t * vec3(1.06, 1.03, 1.0), iris_col, iris);
	col = mix(col, vec3(0.006), pupil);
	float lid = COLOR.r;
	ALBEDO = col * mix(0.2, 1.0, lid);
	ROUGHNESS = 0.4;
	SPECULAR = 0.25 * lid;
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
