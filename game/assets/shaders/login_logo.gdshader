// The emblem on the login screen: a pale sheen sweeps across its metal now
// and then (only where the emblem is drawn).
shader_type canvas_item;

void fragment() {
	// COLOR comes in as the texture times the modulate
	vec4 tex = COLOR;
	float cycle = fract((TIME - 1.4) / 6.5);
	float x = UV.x + (1.0 - UV.y) * 0.25;
	float centre = mix(1.3, -0.3, clamp(cycle / 0.28, 0.0, 1.0));
	float band = (1.0 - smoothstep(0.0, 0.07, abs(x - centre))) * step(cycle, 0.28);
	vec3 col = tex.rgb + vec3(1.0, 0.97, 0.86) * band * 0.75 * tex.a;
	COLOR = vec4(col, tex.a);
}
