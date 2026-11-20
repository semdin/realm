shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

// Overlay on the chest model (both parts): the light of what lies inside
// leaking through the seam under the lid (a thin hot line that flickers along
// it, and a soft spill a few centimetres around it), a faint fresnel rim, and
// on an enchanted chest arcane veins: the erosion noise's mid line crawling
// over the boards, lit where a slower noise pulses through it.
// `seam_y` is the seam's height in the mesh's own space and `seam_dir` which
// side the mesh is on (+1: the body, under it; -1: the lid, over it); `leak`
// fades out as the lid opens. Breathes on its own (TIME, `phase`).
// The same meshes carry chest_inside's instance uniforms (slots 14, 15): the
// slots are fixed so neither shader reads the other's values.
instance uniform vec4 tint : source_color, instance_index(0) = vec4(1.0, 0.8, 0.35, 1.0);
instance uniform float strength : instance_index(1) = 0.3;
instance uniform float leak : instance_index(2) = 1.0;
instance uniform float veins : instance_index(3) = 0.0;
instance uniform float seam_y : instance_index(4) = 0.238;
instance uniform float seam_dir : instance_index(5) = 1.0;
instance uniform float phase : instance_index(6) = 0.0;
instance uniform float speed : instance_index(7) = 1.6;
uniform sampler2D noise : hint_default_white, filter_linear_mipmap, repeat_enable;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	float t = TIME;
	float breathe = 0.8 + 0.2 * sin(t * speed + phase);
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	float d = max((seam_y - local_pos.y) * seam_dir, 0.0);
	// broken along its length: where the noise is low the crack is shut
	float flick = texture(noise, vec2(local_pos.x * 1.6 + local_pos.z * 1.6 + phase, t * 0.07)).r;
	float open_crack = smoothstep(0.38, 0.72, flick);
	float seam = exp(-d / 0.005) * open_crack * 0.9 + exp(-d / 0.04) * 0.25 * open_crack;
	vec3 hot = mix(tint.rgb, vec3(1.0, 0.94, 0.8), 0.25);
	vec3 colour = tint.rgb * f * strength + hot * seam * leak * 1.3;
	if (veins > 0.0) {
		vec2 vu = vec2(local_pos.x + local_pos.z * 0.7, local_pos.y) * 2.6;
		float n = texture(noise, vu + vec2(t * 0.015, -t * 0.022)).r;
		float line = 1.0 - smoothstep(0.0, 0.03, abs(n - 0.52));
		float pulse = smoothstep(0.45, 0.85, texture(noise, vu * 0.45 + vec2(0.0, -t * 0.11) + phase).r);
		colour += mix(tint.rgb, vec3(1.0), 0.25) * line * pulse * veins * 1.6;
	}
	ALBEDO = colour * breathe;
}
