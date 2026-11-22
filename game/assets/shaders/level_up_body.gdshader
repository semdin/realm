shader_type spatial;
// The hero lit from within as the level is gained (LevelUpFX, laid over the
// body's own materials as an overlay for about a second): a band of light
// sweeping up from the feet to the crown as the column erupts, then a warm
// rim round the silhouette that fades. The band is broken by the spells'
// erosion cloud, so it climbs as a flicker of light, not a ruled line.
// Painted light (bloom is off on the low preset); additive.
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform vec4 tint : source_color = vec4(1.0, 0.74, 0.32, 1.0);
uniform vec4 hot : source_color = vec4(1.0, 0.95, 0.82, 1.0);
uniform float age = 0.0;
uniform vec3 feet = vec3(0.0);   // world position of the hero's feet
uniform float body_height = 1.9;
uniform float sweep_time = 0.5;
uniform float gone_at = 1.6;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 p = v_world - feet;
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.4);
	float n = texture(noise, p.xz * 1.6 + vec2(p.y * 0.7, p.y * 0.35 - age * 1.4)).r;

	// the sweep: a soft band climbing the body, gone once it passes the crown
	float k = clamp(age / sweep_time, 0.0, 1.0);
	float level = mix(-0.25, body_height + 0.35, 1.0 - pow(1.0 - k, 1.6));
	float d = p.y - level;
	float band = exp(-(d * d) / 0.035) * (0.45 + 0.8 * n);
	// what it has passed keeps a glow that drains out
	float passed = (1.0 - smoothstep(-0.05, 0.25, d)) * 0.35 * (0.6 + 0.5 * n);
	float sweep = (band + passed) * (1.0 - smoothstep(sweep_time * 0.8, sweep_time + 0.25, age));

	float env = smoothstep(0.0, 0.05, age) * (1.0 - smoothstep(0.35, gone_at, age));
	float glow = rim * (0.7 + 0.5 * n) * env * 0.9 + sweep * 0.55 + env * 0.07;
	vec3 colour = mix(tint.rgb, hot.rgb, clamp(band * 0.8 + rim * 0.3, 0.0, 1.0));
	ALBEDO = colour * min(glow, 1.0);
}
