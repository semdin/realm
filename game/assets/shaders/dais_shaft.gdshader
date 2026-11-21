shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_front, shadows_disabled, fog_disabled;

// The light falling on the character screen's dais from high above: an open
// cone drawn by its inside faces only, so it shows behind the character and
// never veils the face. Brightest at the stone and fading up into the dark,
// soft at its sides (it faces the eye most at its middle), with haze from the
// cloud map drifting slowly up through it.

uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_black;
uniform vec4 tint : source_color = vec4(1.0, 0.92, 0.8, 1.0);
uniform float strength = 0.07;

varying vec3 local;

void vertex() {
	local = VERTEX;
}

void fragment() {
	// UV.y: 0 at the top of the cone, 1 at the stone
	float v = UV.y;
	float rise = smoothstep(0.0, 0.9, v) * (1.0 - smoothstep(0.97, 1.0, v) * 0.6);
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float soft = pow(facing, 2.2);
	float a = atan(local.z, local.x) / 6.2831853;
	float haze = texture(noise, vec2(a * 3.0, v * 1.6 - TIME * 0.018)).r;
	haze = 0.55 + 0.9 * haze * texture(noise, vec2(a * 7.0 + 0.3, v * 3.0 - TIME * 0.031)).r;
	ALBEDO = tint.rgb * rise * soft * haze * strength;
}
