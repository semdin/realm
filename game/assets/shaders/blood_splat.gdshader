shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, specular_schlick_ggx, shadows_disabled;

// A spot of blood on the ground under a bleeding body (StatusFX): its edge
// is the erosion noise cut against a falloff from the middle, so every spot
// is ragged with a few flung drops round it, not a soft disc; wet and dark,
// thinning at the rim. Each spot reads the noise at its own place (world
// position), so no two are alike. It dries away by the instance's own
// transparency (StatusFX tweens it).
uniform sampler2D noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 blood : source_color = vec3(0.28, 0.0, 0.01);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 c = UV * 2.0 - 1.0;
	float r = length(c);
	vec2 at = world_pos.xz * 2.6 + NODE_POSITION_WORLD.xz * 1.7;
	float n = texture(noise, at).r * 0.65 + texture(noise, at * 3.1 + 0.4).r * 0.35;
	// the pool: solid in the middle, eaten ragged toward the rim; drops beyond
	float body = smoothstep(0.02, 0.0, (r - 0.55) - (n - 0.5) * 0.7);
	float drops = smoothstep(0.78, 0.84, n) * smoothstep(1.0, 0.6, r);
	float a = max(body, drops);
	float edge = smoothstep(0.0, 0.25, body);
	ALBEDO = blood * mix(1.5, 0.75, edge);
	ROUGHNESS = 0.12;
	SPECULAR = 0.7;
	ALPHA = a * mix(0.55, 0.92, edge);
}
