shader_type spatial;
// A body bound where it stands (StatusFX rooted): silk wound round its legs
// and waist. Worn on an open tapered tube round the lower body: strands wind
// round it at two slants, each one wandering and breaking up with the noise,
// over a thin milky film that is torn through; the top edge frays out. The
// silk catches the light (lit, soft sheen); see-through so the legs show.
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;
uniform vec4 silk : source_color = vec4(0.94, 0.93, 0.98, 1.0);
// Strands round the tube (per family) and how far each slant climbs per turn.
uniform float strands = 7.0;
uniform float slant = 1.6;
uniform float film = 0.22;
// 0..1: the silk appears (wound on) and goes (StatusFX fades it).
instance uniform float wound : hint_range(0.0, 1.0) = 1.0;

float strand(vec2 uv, float s, float offset, float width) {
	float wobble = texture(noise_tex, vec2(uv.x * 1.3 + offset, uv.y * 0.6)).r - 0.5;
	float x = fract((uv.x + uv.y * s) * strands + offset + wobble * 0.9);
	float line = smoothstep(width, 0.0, abs(x - 0.5));
	// silk is never whole: stretches of each strand thin away
	float keep = smoothstep(0.32, 0.6, texture(noise_tex, vec2(uv.x * 2.1 - offset, uv.y * 1.4 + offset)).r);
	return line * keep;
}

void fragment() {
	// UV.y runs down the tube (0 at the top edge)
	vec2 uv = vec2(UV.x, 1.0 - UV.y);
	float a = strand(uv, slant / strands, 0.13, 0.11);
	float b = strand(uv, -slant / strands, 0.61, 0.09);
	float c = strand(uv * vec2(1.0, 1.7), slant * 0.5 / strands, 0.37, 0.07) * 0.7;
	float threads = max(max(a, b), c);
	float sheet = film * smoothstep(0.38, 0.72, texture(noise_tex, uv * vec2(2.0, 1.2) + 0.2).r);
	// the top frays into loose ends; the foot sits thick on the ground
	float top = smoothstep(1.0, 0.72, uv.y + (texture(noise_tex, vec2(uv.x * 3.0, 0.31)).r - 0.5) * 0.3);
	float foot = mix(1.25, 1.0, smoothstep(0.0, 0.25, uv.y));
	ALPHA = clamp((threads * 0.85 + sheet) * top * foot, 0.0, 1.0) * wound;
	ALBEDO = silk.rgb;
	ROUGHNESS = 0.55;
	SPECULAR = 0.45;
	// a faint sheen toward the light-facing rim reads as silk, not cloth
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	EMISSION = silk.rgb * (0.06 + rim * 0.12) * ALPHA;
}
