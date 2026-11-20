shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// The light a loot chest spills on the ground (a flat disc, UVs over a
// square `size` metres across centred under it: ChestView's pool mesh): a hot contact glow right at its foot, caustic
// filaments where two drifting erosion noises cross (warped by the flow map,
// so they crawl like light through water), faint rays fanning out over the
// ground, all inside a reach whose edge the noise tears so it is never a
// drawn circle. On the opening (`burst` 0..1) a ring of light runs out,
// eroded by the same noise. It breathes on its own (TIME and `phase`), so
// the chest feeds it nothing frame to frame.
// Premultiplied, like the game's sparks: light added on dark ground, while on
// bright ground in daylight its colour tints the ground instead of washing it
// to white.
instance uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.35, 1.0);
instance uniform float strength = 1.0;
instance uniform float phase = 0.0;
instance uniform float speed = 1.6;
instance uniform float burst = 0.0;
uniform sampler2D noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D flow : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float size = 3.4;

void fragment() {
	vec2 p = (UV - 0.5) * size;
	float r = length(p);
	float a = atan(p.y, p.x) / 6.2831853 + 0.5;
	float t = TIME;
	float breathe = 0.84 + 0.16 * sin(t * speed + phase);
	vec2 f = texture(flow, p * 0.11 + vec2(t * 0.011, -t * 0.014)).rg - 0.5;
	vec2 q = p + f * 0.7;
	float n1 = texture(noise, q * 0.42 + vec2(t * 0.026, t * 0.017)).r;
	float n2 = texture(noise, q * 0.71 - vec2(t * 0.019, -t * 0.03)).r;
	float caustic = pow(clamp(1.0 - abs(n1 + n2 - 1.0) * 2.6, 0.0, 1.0), 3.0);
	float rays = smoothstep(0.5, 0.9, texture(noise, vec2(a * 3.0 + phase * 0.1, r * 0.16 - t * 0.035)).r);
	float torn = texture(noise, vec2(a * 2.0, phase * 0.07 + t * 0.012)).r;
	float reach = 0.78 + 0.34 * torn;
	float fall = exp(-pow(r / reach, 2.0) * 1.7);
	float core = exp(-r * r * 10.0);
	float light = core * 1.4 + fall * (0.14 + caustic * 0.85 + rays * 0.28);
	if (burst > 0.0 && burst < 1.0) {
		float run = 1.0 - pow(1.0 - burst, 2.2);
		float rr = mix(0.25, 2.3, run);
		float w = 0.08 + 0.2 * run;
		float ring = exp(-pow((r - rr) / w, 2.0)) * smoothstep(0.2, 0.75, n1 + n2 * 0.4);
		light += ring * 0.95 * (1.0 - burst) + core * 0.5 * (1.0 - run);
	}
	// nothing at the disc's own edge
	light *= smoothstep(size * 0.47, size * 0.38, r);
	light *= strength * breathe;
	vec3 hot = mix(tint.rgb, vec3(1.0, 0.97, 0.9), clamp(core * 0.7 + caustic * fall * 0.25, 0.0, 1.0));
	ALBEDO = hot * light;
	ALPHA = clamp(light * 0.3, 0.0, 0.85);
}
