shader_type spatial;
// The level-up moment's column of light (LevelUpFX): an open cylinder round
// the hero that shoots up out of the ground, flares at its foot, then thins
// and lifts off into the sky, its foot burning away first.
//
// No drawn edge anywhere: every pixel is lit by how squarely it faces the eye
// (a soft body and a narrow hot core, so the column has no silhouette from
// any side), and its body is the spells' erosion cloud stretched into rays
// streaming upward, two layers against each other, with a few strands of it
// winding up round the hero. Both faces are drawn, so the far side's rays
// move behind the near side's and the light has depth.
//
// One uniform drives it (`age`, seconds since the level was gained); the
// mesh is a unit cylinder (CylinderMesh, radius 1, height 1) shaped here.
// Painted light only: bloom is off on the low preset, and the colour stays
// at or under 1 so ACES keeps it gold. Premultiplied, with a little cover:
// added alone over a pale sky the gold went white.
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform vec4 tint : source_color = vec4(1.0, 0.7, 0.28, 1.0);
uniform vec4 hot : source_color = vec4(1.0, 0.95, 0.80, 1.0);
uniform float age = 0.0;
uniform float height = 9.0;     // metres the column reaches
uniform float radius = 0.72;    // metres, the column's settled radius at the hero
uniform float strength = 1.0;
// seconds: shot up, burning bright, and gone
uniform float rise_time = 0.28;
uniform float lift_from = 1.45;
uniform float gone_at = 3.0;
// Soft-particle fade where the column meets the ground, a wall or a ceiling
// (indoors it would otherwise cut a hard ring into the roof).
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform float soft_fade = 0.35;

varying float v_y;      // metres above the ground
varying float v_top;    // metres: the column's current top

void vertex() {
	float y01 = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	float k = clamp(age / rise_time, 0.0, 1.0);
	float top = height * (1.0 - pow(1.0 - k, 3.0));
	float y = y01 * top;
	// swollen as it bursts out, settling, then drawing in as it lifts away
	float swell = 1.0 + 0.35 * exp(-age * 6.0);
	float thin = mix(1.0, 0.5, smoothstep(0.6, gone_at, age));
	// a wide foot that hugs the ground, narrowing up the column
	float foot = 1.0 + 0.6 * exp(-y * 1.8);
	float taper = mix(1.0, 0.7, y01);
	// a slow sway in its width, so it never stands as a straight tube
	float sway = 1.0 + 0.1 * sin(y * 1.1 - age * 2.6) + 0.06 * sin(y * 2.7 + age * 1.9);
	float r = radius * swell * thin * foot * taper * sway;
	VERTEX.xz *= r;
	VERTEX.y = y;
	v_y = y;
	v_top = top;
}

void fragment() {
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float around = UV.x;   // 0..1 round the cylinder; whole noise tiles wrap seamlessly
	float y = v_y;

	// rays: the cloud stretched up the column, streaming up fast
	float n1 = texture(noise, vec2(around * 3.0, y * 0.06 - age * 0.95)).r;
	float n2 = texture(noise, vec2(around * 5.0 + 0.37, y * 0.15 - age * 2.3)).r;
	float rays = smoothstep(0.28, 0.86, n1 * 0.62 + n2 * 0.5);

	// strands winding up round the hero, broken by the cloud so they read
	// as currents in the light, not stripes
	float wind = around * 2.0 - y * 0.32 + age * 0.75 + (n1 - 0.5) * 0.35;
	float strand = pow(0.5 + 0.5 * cos(wind * 6.2831853), 14.0);
	float strand_keep = smoothstep(0.42, 0.78, texture(noise, vec2(around * 3.0 + 0.61, y * 0.12 - age * 1.6)).r);
	strand *= strand_keep * smoothstep(0.15, 0.6, y) * (1.0 - smoothstep(4.5, 7.0, y));

	// light over time: a burst as it erupts, a steady burn, then gone
	float flash = exp(-max(age - 0.06, 0.0) * 4.5);
	float burn = smoothstep(0.0, 0.05, age) * (1.0 - smoothstep(lift_from + 0.4, gone_at, age));
	float env = burn * (0.62 + 0.4 * flash);

	// bright at the foot, thinning upward; the top a ragged front
	float fall = 0.18 + 0.82 * exp(-y * 0.34);
	float front = 1.0 - smoothstep(v_top - (0.8 + 2.4 * n2), v_top, y);
	// a soft foot where the cylinder meets the ground (the ground glow takes it)
	float foot = smoothstep(0.0, 0.3, y);

	// lifting off: the foot burns away upward, raggedly
	float lift = mix(-3.0, height * 0.85, smoothstep(lift_from, gone_at, age));
	float erode = texture(noise, vec2(around * 2.0 + 0.13, y * 0.14 - age * 0.5)).r;
	float stays = smoothstep(lift - 0.5, lift + 0.7, y + (erode - 0.5) * 2.6);

	float body = pow(facing, 1.7);
	float core = pow(facing, 8.0);
	float light = body * (0.1 + 0.72 * rays * rays) + core * (0.12 + 0.3 * n2 * rays) + strand * body * 0.7;
	float depth_raw = texture(depth_tex, SCREEN_UV).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	float soft = clamp((-behind.z / max(1e-5, behind.w) + VERTEX.z) / soft_fade, 0.0, 1.0);
	light *= env * fall * front * foot * stays * soft * strength;

	float heat = clamp(core * 0.5 * rays + flash * 0.25 + strand * 0.45, 0.0, 1.0);
	vec3 colour = mix(tint.rgb, hot.rgb, heat);
	ALBEDO = colour * min(light, 1.0);
	ALPHA = clamp(light * 0.55, 0.0, 0.5);
}
