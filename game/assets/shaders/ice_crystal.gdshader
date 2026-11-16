shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, specular_schlick_ggx, shadows_disabled;

// The ice shards a freeze grows round a body's feet (StatusFX): clear ice
// whose body is a deep blue going pale where frost and cracks (the erosion
// noise, laid on by world position from two sides so no UV seam shows) cloud
// it, a bright cold rim where it turns from the eye, and a sharp glint. Seen
// through where it is clear.
uniform sampler2D noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 deep : source_color = vec3(0.16, 0.38, 0.62);
uniform vec3 pale : source_color = vec3(0.82, 0.94, 1.0);
uniform float noise_scale = 1.6;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 w = abs(world_normal);
	float a = texture(noise, world_pos.xy * noise_scale).r;
	float b = texture(noise, world_pos.zy * noise_scale + 0.37).r;
	float frost = mix(a, b, smoothstep(0.3, 0.7, w.x / max(0.001, w.x + w.z)));
	float cracks = smoothstep(0.62, 0.8, texture(noise, world_pos.xz * noise_scale * 3.1 + world_pos.y * 0.7).r);
	frost = clamp(frost * 0.8 + cracks * 0.6, 0.0, 1.0);
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = mix(deep, pale, frost * 0.85);
	ROUGHNESS = mix(0.04, 0.5, frost);
	METALLIC = 0.0;
	SPECULAR = 0.9;
	EMISSION = pale * (rim * 0.55 + cracks * 0.12) + deep * 0.05;
	ALPHA = clamp(0.32 + frost * 0.38 + rim * 0.4, 0.0, 0.92);
}
