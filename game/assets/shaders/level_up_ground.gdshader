shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_front, shadows_disabled, fog_disabled;

// The level-up moment on the ground (LevelUpFX): a pool of warm light under
// the hero where the column stands, a shockwave of light and dust racing
// out over the ground as it erupts, and short rays thrown out from the foot.
// Nothing drawn: the shockwave's front is the spells' erosion cloud run round
// it (ragged, never a circle), the dust in its wake is the same cloud
// streaked outward, and the pool breathes with it.
//
// Projected like the target ring and the boss warnings: the mesh is a box
// round the hero's feet and the light lands on whatever ground shows through
// it, so it lies on a slope or a stair instead of cutting into it.
// Premultiplied blend: light added, with a little cover so it holds its
// colour on pale stone. One uniform drives it (`age`, seconds).

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform vec4 tint : source_color = vec4(1.0, 0.72, 0.30, 1.0);
uniform vec4 hot : source_color = vec4(1.0, 0.94, 0.78, 1.0);
uniform float age = 0.0;
uniform float reach = 4.6;        // metres the shockwave runs out to
uniform float pool_radius = 1.05; // metres: the warm pool under the hero
uniform float half_height = 0.8;  // metres above and below the feet the light may fall
uniform float shock_time = 0.95;  // seconds the shockwave takes to run out
uniform float gone_at = 3.1;
uniform float strength = 1.0;

void fragment() {
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	view_pos.xyz /= view_pos.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view_pos.xyz, 1.0)).xyz;
	vec3 local = world - MODEL_MATRIX[3].xyz;
	vec3 facing = normalize(cross(dFdx(world), dFdy(world)));
	float ground = smoothstep(0.45, 0.75, abs(facing.y))
		* (1.0 - smoothstep(half_height * 0.7, half_height, abs(local.y)));

	float r = length(local.xz);
	float around = atan(local.z, local.x) / 6.2831853;   // -0.5 .. 0.5

	// the pool: warm light under the hero, its cloud slowly turning
	float pn = texture(noise, local.xz * 0.32 + vec2(age * 0.07, -age * 0.05)).r;
	float pn2 = texture(noise, local.xz * 0.75 - vec2(age * 0.11, age * 0.04)).r;
	float pool_shape = exp(-(r * r) / (pool_radius * pool_radius) * (0.8 + 0.7 * pn));
	float flash = exp(-max(age - 0.05, 0.0) * 4.0);
	float pool_env = smoothstep(0.0, 0.04, age) * (0.5 + 0.8 * flash) * (1.0 - smoothstep(1.3, gone_at, age));
	float pool = pool_shape * (0.55 + 0.55 * pn2) * pool_env;

	// the shockwave: a front racing out, decelerating, ragged all round
	float k = clamp(age / shock_time, 0.0, 1.0);
	float front_r = 0.35 + (reach - 0.35) * (1.0 - pow(1.0 - k, 2.4));
	float rag = textureLod(noise, vec2(around * 5.0, age * 0.35 + 0.2), 1.0).r;
	float rag2 = textureLod(noise, vec2(around * 11.0 + 0.5, r * 0.3), 1.0).r;
	float off = r - front_r * (1.0 + (rag - 0.5) * 0.22 + (rag2 - 0.5) * 0.08);
	float width = 0.16 + 0.55 * k;
	float lead = exp(-max(off, 0.0) / (0.08 + 0.12 * k));
	float wake = exp(-max(-off, 0.0) / width);
	// dust: the cloud streaked outward behind the front
	// (sampled at a fixed level of detail: round the ring the angle wraps,
	// and a derivative across the wrap would draw a seam)
	float streak = textureLod(noise, vec2(around * 9.0, r * 0.22 - age * 0.5), 0.5).r;
	float grit = texture(noise, local.xz * 1.3 + vec2(age * 0.3)).r;
	float dust = smoothstep(0.3, 0.85, streak * 0.7 + grit * 0.45);
	float shock_env = smoothstep(0.0, 0.03, age) * pow(1.0 - k, 1.4);
	float shock = lead * wake * (0.35 + 0.95 * dust) * shock_env;

	// rays thrown out from the foot as it erupts
	float ray_n = textureLod(noise, vec2(around * 7.0 + 0.3, r * 0.06 - age * 0.25), 1.0).r;
	float rays = smoothstep(0.5, 0.92, ray_n) * exp(-r / 1.4) * smoothstep(0.25, 0.7, r)
		* exp(-max(age - 0.05, 0.0) * 3.2) * smoothstep(0.0, 0.05, age);

	float heat = (pool + shock + rays * 0.55) * strength;
	float h = clamp(heat, 0.0, 1.0);
	vec3 deep = tint.rgb * tint.rgb * 0.9;
	vec3 light = mix(deep, tint.rgb, smoothstep(0.0, 0.35, h));
	light = mix(light, hot.rgb, smoothstep(0.45, 1.0, h));
	ALBEDO = light * min(heat, 1.0) * ground;
	ALPHA = clamp(heat * 0.22, 0.0, 0.3) * ground;
}
