shader_type spatial;
// Draw pass of the broom wake's mist (broom_wake.gdshader sets each particle's
// basis: X = its width, Y = its stretch along the travel direction). A quad
// turned to the camera with its long side along the travel direction as the
// camera sees it: seen from the side a young puff is a wisp drawn out along
// the flight, seen from behind it is round. Each one plays the broom mist
// flipbook (a fal Wan clip of curling smoke) from a random early frame to its
// end over its life, turned and mirrored by its seed, and is worn away by the
// erosion noise as it thins, so no two read alike and none ends on a hard
// edge. Lit by the scene (per vertex: four lights a quad), so the wake is
// white smoke at noon and grey at night instead of glowing.
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform,
	vertex_lighting, diffuse_lambert_wrap, specular_disabled;

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D erosion : filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(0.86, 0.89, 0.93, 1.0);
uniform float first_frame_max = 20.0;

varying vec2 v_uv;
varying float v_frame;
varying float v_alpha;
varying float v_age;
varying vec2 v_noise_at;

void vertex() {
	vec3 centre = MODEL_MATRIX[3].xyz;
	float width = length(MODEL_MATRIX[0].xyz);
	vec3 along_v = MODEL_MATRIX[1].xyz;
	float stretched = length(along_v);
	vec3 along = stretched > 0.00001 ? along_v / stretched : vec3(0.0, 1.0, 0.0);
	vec3 to_camera = normalize(CAMERA_POSITION_WORLD - centre);
	// the travel direction on the view plane; looking down it, the puff is round
	vec3 flat_along = along - to_camera * dot(along, to_camera);
	float seen = length(flat_along);
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 axis = seen > 0.0001 ? flat_along / seen : up;
	axis = normalize(mix(up, axis, smoothstep(0.05, 0.35, seen)));
	vec3 across = normalize(cross(axis, to_camera));
	float half_len = mix(width, stretched, seen) * 0.5;
	float half_wide = width * 0.5;
	vec3 world = centre + across * VERTEX.x * 2.0 * half_wide + axis * VERTEX.y * 2.0 * half_len;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	// lit mostly from above, a little toward the eye (a puff, not a card)
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(vec3(0.0, 1.0, 0.0) * 0.75 + to_camera * 0.55), 0.0)).xyz);
	float seed = INSTANCE_CUSTOM.x;
	v_age = INSTANCE_CUSTOM.y;
	// turn the picture inside its cell and mirror half of them
	float angle = seed * 6.2831853 * 7.0;
	vec2 uv = UV - 0.5;
	if (fract(seed * 13.37) > 0.5) {
		uv.x = -uv.x;
	}
	uv = vec2(uv.x * cos(angle) - uv.y * sin(angle), uv.x * sin(angle) + uv.y * cos(angle));
	v_uv = uv + 0.5;
	float first = 4.0 + floor(fract(seed * 71.3) * first_frame_max);
	v_frame = floor(mix(first, 63.0, clamp(v_age, 0.0, 1.0)));
	v_alpha = COLOR.a;
	v_noise_at = vec2(fract(seed * 3.7), fract(seed * 9.1));
}

void fragment() {
	// the rotated corners fall outside the cell: nothing there
	vec2 inside = step(vec2(0.0), v_uv) * step(v_uv, vec2(1.0));
	vec2 cell = vec2(mod(v_frame, 8.0), floor(v_frame / 8.0));
	vec4 smoke = texture(atlas, (cell + clamp(v_uv, 0.0, 1.0)) / 8.0);
	float n = texture(erosion, UV * 0.55 + v_noise_at + vec2(TIME * 0.03, 0.0)).r;
	// worn away from the thin parts first as it ages
	float eaten = smoothstep(v_age * 0.85 - 0.15, v_age * 0.85 + 0.2, n);
	ALBEDO = tint.rgb * mix(0.85, 1.0, smoke.r);
	ALPHA = clamp(smoke.a * v_alpha * eaten * inside.x * inside.y * tint.a, 0.0, 1.0);
}
