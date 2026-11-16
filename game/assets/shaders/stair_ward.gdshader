shader_type spatial;
// A moving staircase's gate ward (StairView): a shimmering veil standing in
// the plane of the server's gate collider, as tall as that collider, whose
// ragged crest licks a little higher and fades. Everything in it comes from
// noise: two drifting, domain-warped samples of an erosion map make the
// veil's body and its shimmer, and embers rise along its edges and crest
// (hashed cells, round soft sparks). No glyphs, no ruled lines, no flat fill.
// The veil grows from the floor as its gate shuts and sinks as it opens.
//   closed 0..1 - how far the veil stands (0 = sunk, gate open)
//   tint        - state colour (gold open / amber warning / violet sealed)
// QuadMesh UV: x across the gate, y = 0 at the quad's top.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D noise : hint_default_black, repeat_enable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(1.0, 0.75, 0.35, 1.0);
uniform float closed = 1.0;
uniform float pulse = 0.0;
uniform float width_m = 5.0;
// the quad's height and the gate collider's (the veil's solid part)
uniform float height_m = 1.8;
uniform float gate_m = 1.2;
uniform float strength = 1.0;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

// Embers: one candidate spark per cell of a grid rising through the veil;
// `x`, `y` in metres.
float embers(vec2 m, float rate, float t) {
	vec2 g = vec2(m.x * 3.2, m.y * 2.4 - t * rate);
	vec2 cell = floor(g);
	vec2 f = fract(g);
	float lit = 0.0;
	for (int i = -1; i <= 1; i++) {
		vec2 c = cell + vec2(float(i), 0.0);
		float r = hash(c);
		if (r < 0.5) {
			continue;
		}
		vec2 at = vec2(hash(c + 3.7), hash(c + 9.1));
		// sway a little sideways as it rises
		at.x += 0.18 * sin(t * 2.3 + r * 40.0);
		vec2 d = (f - vec2(float(i), 0.0) - at) * vec2(1.0, 1.4);
		float s = smoothstep(0.2, 0.0, length(d));
		float flicker = 0.55 + 0.45 * sin(t * (5.0 + r * 9.0) + r * 60.0);
		lit += s * s * flicker;
	}
	return lit;
}

void fragment() {
	float t = TIME;
	float x = UV.x * width_m;                    // metres across
	float up = (1.0 - UV.y) * height_m;          // metres over the floor
	float crest = closed * gate_m;               // the veil's top now
	// body noise: two drifting samples, one warping the other, stretched
	// upward so the veil streams like heat over a fire
	vec2 p = vec2(x * 0.42, up * 0.16);
	float warp = texture(noise, p * 0.8 + vec2(t * 0.011, -t * 0.06)).r;
	float body = texture(noise, p + vec2(warp * 0.35 - t * 0.015, -t * 0.12 + warp * 0.25)).r;
	float fine = texture(noise, vec2(x * 1.1, up * 0.5) + vec2(t * 0.02, -t * 0.32) + warp * 0.3).r;
	// the ragged crest: the top wavers with the noise and fades over ~0.5 m
	float ragged = crest + (body - 0.5) * 0.5 + 0.12;
	float height_mask = 1.0 - smoothstep(ragged - 0.45, ragged + 0.05, up);
	// soft, noisy flanks: the veil thins over its last ~0.3 m each side
	float side = min(x, width_m - x);
	float flank = smoothstep(0.0, 0.35 + body * 0.35, side);
	// density: holes and wisps from the noise, thicker low down, thinning
	// and shimmering higher up
	float dense = smoothstep(0.42, 0.95, body * 0.7 + fine * 0.5) * (0.45 + 0.7 * fine);
	dense *= mix(1.0, 0.35, smoothstep(0.0, max(gate_m, 0.1), up));
	// the floor seam: where the veil meets the floor it glows in pools
	float seam = exp(-up * 7.0) * smoothstep(0.25, 0.8, body + fine * 0.3) * 0.7;
	float veil = (dense * 0.3 + seam + 0.03) * height_mask * flank;
	// embers: rising from the floor along both flanks and drifting off the crest
	float edge_w = exp(-side * 1.4) * 0.75 + exp(-pow((up - crest) / 0.35, 2.0)) * 0.7 + 0.15;
	float sparks = embers(vec2(x, up), 0.9 + pulse * 1.2, t) * edge_w;
	sparks *= smoothstep(crest + 0.9, crest, up) * step(0.02, closed);
	float fade = smoothstep(0.0, 0.12, closed) * (1.0 + pulse * 0.8) * strength;
	veil *= 0.85 + 0.15 * sin(t * 1.7 + body * 6.0);
	// embers burn hotter (towards white-gold) than the veil
	vec3 ember_col = mix(tint.rgb, vec3(1.0, 0.85, 0.6), 0.45);
	// the brightest wisps pale toward white: the veil's light, not a fill
	vec3 soft = mix(tint.rgb, vec3(dot(tint.rgb, vec3(0.333))), 0.3);
	vec3 veil_col = mix(soft, vec3(1.0, 0.95, 1.0), smoothstep(0.6, 1.0, fine) * 0.3);
	ALBEDO = (veil_col * veil * 1.3 + ember_col * sparks * 1.8) * fade;
}
