// The login card: dark frosted glass (the world behind it blurred), a fine
// gold frame lit at the top, a glowing top rule, gold corner brackets and a
// soft drop shadow. Drawn on a StyleBoxTexture that reaches `pad` beyond the
// card on every side (the shadow's room); UV runs over that whole rect.
shader_type canvas_item;

uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap;
// The drawn rect (card + pad on each side), canvas units.
uniform vec2 size = vec2(520.0, 520.0);
uniform float pad = 40.0;
uniform float radius = 10.0;
uniform vec3 gold_hi : source_color = vec3(0.957, 0.886, 0.627);
uniform vec3 gold : source_color = vec3(0.659, 0.537, 0.184);
uniform vec3 gold_lt : source_color = vec3(0.847, 0.714, 0.290);

void fragment() {
	vec2 p = UV * size - pad;
	vec2 card = size - 2.0 * pad;
	vec2 q = abs(p - card * 0.5) - (card * 0.5 - radius);
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
	float inside = 1.0 - smoothstep(-0.6, 0.6, d);
	float v = clamp(p.y / card.y, 0.0, 1.0);
	float h = clamp(p.x / card.x, 0.0, 1.0);

	// the shadow under the card
	float shadow = exp(-max(d - 0.0, 0.0) / 16.0) * (1.0 - inside) * smoothstep(-pad, 8.0, p.y - 8.0) * 0.55;

	// the glass: the blurred world behind, darkened toward the bottom
	vec3 behind = textureLod(screen, SCREEN_UV, 4.0).rgb;
	vec3 tint = mix(vec3(0.063, 0.078, 0.122), vec3(0.027, 0.035, 0.059), v);
	vec3 col = mix(behind * 1.1, tint, mix(0.80, 0.90, v));
	col += vec3(1.0, 0.94, 0.78) * 0.03 * (1.0 - smoothstep(0.0, 2.0, p.y)) * inside;

	// the frame: a 1 px ring, bright at the top, faint mid-way, warmer again low
	float ring = 1.0 - smoothstep(0.0, 1.0, abs(d + 0.5));
	float ra = mix(0.75, 0.35, smoothstep(0.0, 0.3, v));
	ra = mix(ra, 0.12, smoothstep(0.3, 0.7, v));
	ra = mix(ra, 0.35, smoothstep(0.7, 1.0, v));
	vec3 frame = mix(gold_hi, gold, smoothstep(0.0, 0.3, v));
	col = mix(col, frame, ring * ra);

	// the top rule: 2 px of lit gold, brightest at the centre
	float rule = (1.0 - smoothstep(0.0, 2.2, abs(p.y + 0.4))) * max(0.0, 1.0 - abs(h - 0.5) / 0.38);
	float rule_glow = exp(-abs(p.y) / 4.0) * max(0.0, 1.0 - abs(h - 0.5) / 0.4) * 0.35;
	col = mix(col, gold_hi, clamp(rule, 0.0, 1.0) * 0.9);

	// corner brackets: 16 px arms, 6 px in from each corner
	vec2 m = min(p, card - p) - 6.0;
	float arm_x = step(0.0, m.x) * step(m.x, 16.0) * step(0.0, m.y) * step(m.y, 1.0);
	float arm_y = step(0.0, m.y) * step(m.y, 16.0) * step(0.0, m.x) * step(m.x, 1.0);
	col = mix(col, gold_lt, clamp(arm_x + arm_y, 0.0, 1.0) * 0.85 * inside);

	float alpha = max(inside, max(shadow, clamp(rule + rule_glow, 0.0, 1.0) * (1.0 - inside)));
	vec3 outside = mix(vec3(0.0), gold_hi, clamp(rule + rule_glow, 0.0, 1.0));
	// the modulate's alpha (the screen's fade-in) still applies
	COLOR = vec4(mix(outside, col, inside), alpha * COLOR.a);
}
