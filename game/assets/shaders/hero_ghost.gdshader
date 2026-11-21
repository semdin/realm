shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

// A hero rising from a death (HeroView.ghost_rise): for a moment the body is
// a spirit. Worn as every piece's material_override (one material per kind
// of piece, shared by all heroes): a cold blue see-through body, strongest
// at its outline, with fine wisps of the erosion noise streaming up through
// it. Blended over what is behind (not added: the cloth over the skin would
// sum to white), never writing depth. A hair card keeps its own coverage (the atlas's
// alpha and its hairline fade), so the hair stays hair-shaped.
// As the body turns solid again the same shader is laid over it as an
// outline only (`shell`), fading out.
// `ghost_fade` (1 .. 0) is per hero; slot 10 is clear of the hero shaders'
// own instance uniforms (hero_instance.gdshaderinc, slots 0-6), which share
// a mesh's slot buffer with this one while it is worn.
instance uniform float ghost_fade : instance_index(10) = 1.0;
uniform sampler2D mask_tex : hint_default_white, filter_linear_mipmap;
uniform bool use_mask = false;
uniform bool card_fade = false;
uniform bool shell = false;
uniform sampler2D noise : hint_default_white, filter_linear_mipmap, repeat_enable;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float cover = 1.0;
	if (use_mask) {
		vec4 a = texture(mask_tex, UV);
		cover = a.a;
		if (card_fade) {
			float th = a.r * 0.8;
			cover *= smoothstep(th, th + 0.2, COLOR.a);
		}
	}
	float facing = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, 2.0);
	float t = TIME;
	// fine wisps, stretched upward and rising
	float n1 = texture(noise, vec2(world_pos.x * 2.4 + world_pos.z * 1.7, world_pos.y * 0.9 - t * 0.45)).r;
	float n2 = texture(noise, vec2(world_pos.z * 3.1 - world_pos.x * 1.3, world_pos.y * 1.6 - t * 0.7)).r;
	float wisp = smoothstep(0.5, 0.95, n1 * 0.55 + n2 * 0.5);
	float body = shell ? 0.0 : 0.1 + 0.18 * wisp;
	float edge = rim * (shell ? 0.7 : 0.85);
	vec3 core = vec3(0.16, 0.34, 0.78);
	vec3 glow = vec3(0.72, 0.9, 1.0);
	ALBEDO = mix(core, glow, clamp(rim * 1.1 + wisp * 0.35, 0.0, 1.0));
	ALPHA = clamp((body + edge) * cover * ghost_fade, 0.0, 0.92);
}
