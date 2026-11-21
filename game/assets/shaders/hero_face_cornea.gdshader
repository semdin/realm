shader_type spatial;
// The hero's corneas (Face_Cornea): clear shells over the eyeballs that add
// only their reflections - the sky's, the lights' tight highlights and a soft
// catch light fixed in view space (a portrait's window), so the eyes read
// wet and alive from any side. Additive: no sorting, no depth write.
render_mode blend_add, depth_draw_never, cull_back, shadows_disabled;
// HeroView.ghost; slot 7 as in hero_instance.gdshaderinc (the face mesh
// shares one slot buffer with hero_face_skin)
instance uniform float ghost : instance_index(7) = 0.0;

uniform float catch_strength = 0.55;

void fragment() {
	ALBEDO = vec3(0.0);
	ROUGHNESS = 0.05;
	SPECULAR = 0.55;
	vec3 r = reflect(-VIEW, NORMAL);
	float catch_light = pow(max(dot(r, normalize(vec3(-0.35, 0.5, 1.0))), 0.0), 260.0);
	EMISSION = vec3(catch_light * catch_strength);
	if (ghost > 0.0 && fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715)))) < ghost) {
		discard;
	}
}
