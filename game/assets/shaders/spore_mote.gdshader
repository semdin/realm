shader_type spatial;
// A drifting cave spore (SpiderCaverns._spores, GPUParticles3D draw pass): a
// small bright core in the particle's colour with a faint halo, never a disc;
// it fades out as the camera comes within `fade_near`..`fade_far` metres, so
// a spore drifting past the third-person camera never fills the screen.
// Billboarded like BILLBOARD_PARTICLES (keeps the particle's scale).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform float fade_near = 2.5;
uniform float fade_far = 7.0;
uniform float glow = 1.0;

varying float fade;

void vertex() {
	mat4 world = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]), normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * world;
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	float dist = length((MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	fade = smoothstep(fade_near, fade_far, dist);
}

void fragment() {
	float r = length(UV - 0.5) * 2.0;
	float core = exp(-r * r * 24.0);
	float halo = exp(-r * r * 6.0) * 0.3;
	ALBEDO = COLOR.rgb * (core + halo) * COLOR.a * fade * glow;
}
