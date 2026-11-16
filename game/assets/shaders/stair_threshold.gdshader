shader_type spatial;
// The floor seam under a staircase gate (StairView): a narrow strip centred
// on the gate's line, no wider than where the server's gate collider stops a
// body, in which light pools out of noise. While the flight may be boarded
// the pools drift across the line toward the flight in gold; while it may
// not they smoulder dimly in the sealed colour. No glyphs, no chevrons.
// PlaneMesh UV: x across the gate, y across the line (0.5 = the gate).
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D noise : hint_default_black, repeat_enable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(1.0, 0.75, 0.35, 1.0);
uniform float open = 0.0;
uniform float width_m = 5.0;
uniform float depth_m = 0.9;
// +1 when the flight lies toward UV.y = 1, -1 toward 0
uniform float toward = 1.0;

void fragment() {
	float t = TIME;
	vec2 m = vec2(UV.x * width_m, (UV.y - 0.5) * depth_m);
	float drift = t * (0.04 + 0.3 * open) * toward;
	float n1 = texture(noise, m * 0.55 + vec2(t * 0.01, -drift)).r;
	float n2 = texture(noise, m * 1.4 + vec2(-t * 0.02, -drift * 1.6) + n1 * 0.3).r;
	float pools = smoothstep(0.35, 0.85, n1 * 0.6 + n2 * 0.55);
	// strongest on the line, gone at the strip's edges; soft at the ends
	float across = exp(-pow(m.y / (depth_m * 0.22), 2.0));
	float ends = smoothstep(0.0, 0.35, min(m.x, width_m - m.x));
	float a = (0.12 + pools * 0.9) * across * ends;
	a *= mix(0.35, 1.0, open);
	ALBEDO = tint.rgb * a * 1.1;
}
