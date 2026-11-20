shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// Glints on a loot chest's corners, lock and lid: each quad of the mesh
// (ChestView builds it: every corner of a quad at its glint's point, UV the
// corner, UV2 its seed and size) is turned to the camera here and drawn as
// the game's four-pointed star flare. A glint winks on for a moment and is
// gone again, each on its own beat, so the chest catches the light now and
// then rather than shining. The quad seeded below 0 is the opening's bloom:
// a soft light over the chest, there only while `flash` is up (every glint
// winks with it). All of it on the GPU; the chest feeds it nothing frame to
// frame.
instance uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.35, 1.0);
instance uniform float strength = 1.0;
instance uniform float flash = 0.0;
instance uniform float phase = 0.0;
uniform sampler2D star : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D glow : source_color, filter_linear_mipmap, repeat_disable;

varying float lit;
varying float bloom;

void vertex() {
	float seed = UV2.x;
	float size = UV2.y;
	bloom = seed < 0.0 ? 1.0 : 0.0;
	float on;
	if (bloom > 0.5) {
		on = flash;
		size *= 0.55 + 0.6 * flash;
	} else {
		float rate = 0.16 + fract(seed * 7.13) * 0.22;
		float beat = fract(TIME * rate + seed + phase);
		on = smoothstep(0.0, 0.05, beat) * (1.0 - smoothstep(0.05, 0.24, beat));
		on = max(on, flash);
		size *= 0.3 + 0.7 * on;
	}
	lit = on;
	// a glint (or the bloom) that is out draws nothing at all
	size *= step(0.01, on);
	vec3 centre = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 corner = (UV - 0.5) * 2.0 * size;
	vec3 world = centre + INV_VIEW_MATRIX[0].xyz * corner.x + INV_VIEW_MATRIX[1].xyz * corner.y;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

void fragment() {
	vec3 colour = mix(tint.rgb, vec3(1.0, 0.98, 0.94), 0.6);
	if (bloom > 0.5) {
		vec4 g = texture(glow, UV);
		ALBEDO = mix(tint.rgb, vec3(1.0), 0.3) * g.a * g.r * lit * strength * 0.55;
	} else {
		vec4 s = texture(star, UV);
		ALBEDO = colour * s.a * s.r * lit * strength * 1.6;
	}
}
