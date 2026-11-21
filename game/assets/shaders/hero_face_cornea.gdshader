shader_type spatial;
// The hero's corneas (Face_Cornea): clear shells over the eyeballs that add
// only their reflections - the sky's, the lights' tight highlights and a soft
// catch light fixed in view space (a portrait's window), so the eyes read
// wet and alive from any side. Additive: no sorting, no depth write.
render_mode blend_add, depth_draw_never, cull_back, shadows_disabled;

uniform float catch_strength = 0.55;

void fragment() {
	ALBEDO = vec3(0.0);
	ROUGHNESS = 0.05;
	SPECULAR = 0.55;
	vec3 r = reflect(-VIEW, NORMAL);
	float catch_light = pow(max(dot(r, normalize(vec3(-0.35, 0.5, 1.0))), 0.0), 260.0);
	EMISSION = vec3(catch_light * catch_strength);
}
