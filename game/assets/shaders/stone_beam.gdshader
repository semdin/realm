// A Dark Shard's light column (StoneView): an open cylinder seen from inside
// and out, strongest at its base and fading upward, with a bright core and a
// soft rim (the side seen edge-on fades out) and slow pulses climbing it. The
// falling stone's comet tail is the same column, narrowing to a point.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 colour : source_color = vec4(0.35, 1.0, 0.45, 0.5);
uniform float strength = 1.0;

void fragment() {
	// UV.y runs top (0) to base (1)
	float rise = pow(UV.y, 1.4);
	float core = pow(abs(dot(NORMAL, VIEW)), 1.6);
	float pulse = 0.72 + 0.28 * sin(UV.y * 36.0 + TIME * 2.6);
	ALBEDO = colour.rgb;
	ALPHA = clamp(colour.a * strength * rise * core * pulse, 0.0, 1.0);
}
