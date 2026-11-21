// The login's big gold button: a lit metal gradient, a bright top edge, a
// darker lip, a warm glow around it that grows on hover, and a sheen that
// sweeps across now and then. Drawn on a rect `pad` larger than the button
// on every side (the glow's room).
shader_type canvas_item;

uniform vec2 size = vec2(440.0, 104.0);
uniform float pad = 24.0;
uniform float radius = 7.0;
uniform float hover : hint_range(0.0, 1.0) = 0.0;
uniform float press : hint_range(0.0, 1.0) = 0.0;
uniform float disabled : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 p = UV * size - pad;
	vec2 b = size - 2.0 * pad;
	vec2 q = abs(p - b * 0.5) - (b * 0.5 - radius);
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
	float inside = 1.0 - smoothstep(-0.6, 0.6, d);
	float v = clamp(p.y / b.y, 0.0, 1.0);

	// the metal: pale gold over a deeper gold, split a little below the middle
	vec3 c0 = vec3(0.969, 0.867, 0.541);
	vec3 c1 = vec3(0.851, 0.698, 0.290);
	vec3 c2 = vec3(0.690, 0.514, 0.157);
	vec3 c3 = vec3(0.549, 0.392, 0.125);
	vec3 col = mix(c0, c1, smoothstep(0.0, 0.46, v));
	col = mix(col, c2, smoothstep(0.46, 0.54, v));
	col = mix(col, c3, smoothstep(0.54, 1.0, v));
	// the top edge's light and the bottom lip's shade
	col = mix(col, vec3(1.0, 0.98, 0.86), (1.0 - smoothstep(0.0, 1.5, p.y)) * 0.85);
	col *= 1.0 - 0.25 * smoothstep(b.y - 2.5, b.y, p.y);
	// a dark 1 px outline
	col = mix(col, vec3(0.0), (1.0 - smoothstep(0.0, 1.0, abs(d + 0.5))) * 0.55);

	// the sheen: a skewed band crossing every 4.2 s
	float cycle = fract((TIME - 2.0) / 4.2);
	float x = (p.x + (b.y - p.y) * 0.36) / b.x;
	float centre = mix(-0.45, 1.3, clamp(cycle / 0.3, 0.0, 1.0));
	float sheen = (1.0 - smoothstep(0.0, 0.19, abs(x - centre))) * step(cycle, 0.3);
	col += vec3(1.0) * sheen * 0.45;

	col *= 1.0 + 0.08 * hover - 0.06 * press;
	float grey = dot(col, vec3(0.3, 0.55, 0.15));
	col = mix(col, vec3(grey) * 0.55, disabled);

	// the glow around it
	float glow = exp(-max(d, 0.0) / mix(10.0, 15.0, hover)) * (1.0 - inside) * mix(0.32, 0.55, hover) * (1.0 - disabled);
	vec3 glow_col = vec3(0.85, 0.63, 0.24);
	float alpha = max(inside, glow);
	COLOR = vec4(mix(glow_col, col, inside), alpha * COLOR.a);
}
