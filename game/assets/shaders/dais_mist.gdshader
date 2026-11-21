shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// A low bank of mist round the foot of the character screen's dais, so the
// stone stands in something instead of ending at a cut edge: a wide flat
// sheet, clear inside the dais and thinning out to nothing far from it, its
// cloud map drifting round slowly (`turn` sets the way, two sheets turn
// against each other).

uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_black;
uniform vec4 tint : source_color = vec4(0.36, 0.4, 0.5, 1.0);
uniform float strength = 0.12;
uniform float turn = 1.0;
uniform float size = 6.0;      // metres across the sheet

void fragment() {
	vec2 p = (UV - 0.5) * size;
	float r = length(p);
	float a = atan(p.y, p.x) / 6.2831853 + TIME * 0.004 * turn;
	float n = texture(noise, vec2(a * 4.0, r * 0.18 - TIME * 0.01)).r;
	n *= texture(noise, p * 0.11 + vec2(TIME * 0.006 * turn, 0.0)).r * 1.6;
	float ring = smoothstep(1.25, 1.55, r) * (1.0 - smoothstep(1.7, 2.7, r));
	ALBEDO = tint.rgb;
	ALPHA = clamp(ring * n * strength, 0.0, 1.0);
}
