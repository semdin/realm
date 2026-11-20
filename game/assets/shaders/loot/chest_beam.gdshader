shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

// The shaft of light over a loot chest, on an open cylinder `height` metres
// tall standing on it. Its faces turned to the camera are its body and its
// grazing ones fade out, so it reads as a soft volume from any side, with a
// thin hot core down the middle; erosion noise streams up it as wisps and fine
// streaks and tears its top away. A plain chest's is short and soft; an
// enchanted one's is a tall pillar seen from afar. Breathes on its own (TIME,
// `phase`); `strength` swells while the chest opens.
instance uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.35, 1.0);
instance uniform float strength = 1.0;
instance uniform float phase = 0.0;
instance uniform float speed = 1.6;
instance uniform float height = 2.0;
uniform sampler2D noise : hint_default_white, filter_linear_mipmap, repeat_enable;

varying float along;

void vertex() {
	along = clamp(VERTEX.y / height + 0.5, 0.0, 1.0);
}

void fragment() {
	float facing = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	float body = pow(facing, 1.8);
	float core = pow(facing, 14.0);
	float t = TIME;
	float metres = along * height;
	// slow soft wisps (low frequency: haze, not falling water), barely streaked
	float wisps = texture(noise, vec2(UV.x * 2.0, metres * 0.2 - t * 0.22 + phase * 0.1)).r;
	wisps = mix(0.5, 1.2, smoothstep(0.25, 0.8, wisps));
	float streaks = texture(noise, vec2(UV.x * 5.0, metres * 0.06 - t * 0.1)).r;
	float foot = smoothstep(0.0, 0.3, metres);
	float top = 1.0 - smoothstep(0.3, 1.0, along + (wisps - 0.9) * 0.22);
	float rise = pow(1.0 - along, 1.15);
	float breathe = 0.82 + 0.18 * sin(t * speed + phase);
	float light = (body * (0.65 + 0.35 * streaks) * wisps + core * 0.6) * foot * top * rise;
	vec3 colour = mix(tint.rgb, vec3(1.0, 0.97, 0.9), clamp(core * 0.45 + (1.0 - along) * 0.08, 0.0, 1.0));
	ALBEDO = colour * light * strength * breathe * 0.75;
}
