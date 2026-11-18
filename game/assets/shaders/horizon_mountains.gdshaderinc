// The grounds' far mountains (maps/grounds/grounds_horizon.gd): grass, rock
// and snow split by slope and height and broken up by noise, the terrain's
// own rock and meadow textures projected at mountain scale, lit like the rest
// of the world (sun or moon, sky ambient), then hazed into the sky's horizon
// colour by their true distance. Nothing here receives shadows: the sun's
// shadow reach ends a few hundred metres out.
//
// The camera's far plane can be shorter than the ranges are far (the low
// preset: 1600 m), so the vertex stage pulls every point past `max_dist`
// * PULL_START towards the camera along its own sight line, compressing the
// distance smoothly and monotonically into the last stretch before the far
// plane: the silhouette and the depth order stay as they are, nothing is
// clipped. Shading and haze use the true position.
//
// Included by horizon_mountains.gdshader and, with LITE defined (the low
// preset's light path: one projection for the rock, no fine bump), by
// horizon_mountains_lite.gdshader.
render_mode world_vertex_coords, cull_back, shadows_disabled, specular_schlick_ggx;

uniform sampler2D rock_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D meadow_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
// what the haze tends to: the sky's horizon colour with the hour's fog in it
uniform vec3 haze_color : source_color = vec3(0.62, 0.70, 0.78);
// the hour's fog density (DayNight; per preset and rain)
uniform float haze_density = 0.0006;
// the camera's far plane (m)
uniform float max_dist = 1600.0;

// linear multipliers on the textures (the terrain's own tints are 0.5 / 0.52)
uniform vec3 rock_tint = vec3(0.50, 0.485, 0.47);
uniform vec3 rock_dark = vec3(0.30, 0.29, 0.30);
uniform vec3 meadow_tint = vec3(0.44, 0.50, 0.38);
uniform vec3 heather_tint = vec3(0.42, 0.36, 0.30);
// linear albedo
uniform vec3 snow_color = vec3(0.36, 0.38, 0.41);
uniform float snow_line = 400.0;

const float PULL_START = 0.82;
const float PULL_END = 0.985;

varying vec3 world_pos;

void vertex() {
	world_pos = VERTEX;
	vec3 to = VERTEX - CAMERA_POSITION_WORLD;
	float dist = length(to);
	float start = max_dist * PULL_START;
	if (dist > start) {
		float span = max_dist * PULL_END - start;
		float pulled = start + span * (1.0 - exp(-(dist - start) / span));
		VERTEX = CAMERA_POSITION_WORLD + to * (pulled / dist);
	}
}

vec3 rock_albedo(vec3 p, vec3 n) {
#ifdef LITE
	vec2 uv = abs(n.x) > abs(n.z) ? p.zy : p.xy;
	return texture(rock_tex, uv / 70.0).rgb;
#else
	vec3 w = pow(abs(n), vec3(4.0));
	w /= (w.x + w.y + w.z);
	return texture(rock_tex, p.zy / 70.0).rgb * w.x
		+ texture(rock_tex, p.xz / 90.0).rgb * w.y
		+ texture(rock_tex, p.xy / 70.0).rgb * w.z;
#endif
}

void fragment() {
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 p = world_pos;
	// noise at three scales: massif colour, patches, fine break-up
	float n_far = texture(noise_tex, p.xz / 2600.0).r;
	float n_mid = texture(noise_tex, p.xz / 640.0 + 0.37).r;
	float n_fine = texture(noise_tex, p.xz / 150.0 + 0.71).r;
	// fine relief: the noise's slope as a bump on the mesh normal
#ifndef LITE
	vec2 e = vec2(6.0 / 512.0, 0.0);
	vec2 uv = p.xz / 260.0;
	float h0 = texture(noise_tex, uv).r;
	float hx = texture(noise_tex, uv + e.xy).r;
	float hz = texture(noise_tex, uv + e.yx).r;
	float steep = 1.0 - smoothstep(0.75, 0.95, n.y);
	n = normalize(n + vec3(h0 - hx, 0.0, h0 - hz) * (2.2 + 3.0 * steep));
#endif
	float slope = n.y;
	float cavity = COLOR.r;
	// strata: bands along the height, wavering with the massif noise
	float strata = texture(noise_tex, vec2(p.y / 46.0 + n_far * 3.0, n_mid * 0.5)).r;
	vec3 rock = rock_albedo(p, n) * mix(rock_dark, rock_tint, smoothstep(0.25, 0.75, n_far * 0.6 + strata * 0.4));
	// grass on the gentle lower slopes, heather browning it higher up
	float grass = smoothstep(0.73, 0.88, slope + (n_mid - 0.5) * 0.35 + (cavity - 0.5) * 0.15);
	grass *= 1.0 - smoothstep(snow_line - 170.0, snow_line - 40.0, p.y + (n_fine - 0.5) * 120.0);
	vec3 meadow = texture(meadow_tex, p.xz / 55.0).rgb;
	meadow *= mix(meadow_tint, heather_tint, smoothstep(0.35, 0.7, n_mid * 0.6 + p.y / 900.0));
	// snow on the high, flatter ground: ledges and crests, not the cliffs
	float snow = smoothstep(snow_line - 30.0, snow_line + 50.0, p.y + (n_mid - 0.5) * 160.0 + (n_fine - 0.5) * 50.0);
	snow *= smoothstep(0.50, 0.72, slope + (n_fine - 0.5) * 0.25);
	vec3 albedo = mix(rock, meadow, grass);
	albedo = mix(albedo, snow_color, snow);
	albedo *= 0.78 + 0.44 * n_fine * n_mid;
	// gullies hold the shade, crests catch the light
	albedo *= mix(0.62, 1.12, cavity);
	ALBEDO = albedo;
	AO = mix(0.45, 1.0, cavity);
	ROUGHNESS = mix(0.95, 0.7, snow);
	SPECULAR = mix(0.2, 0.3, snow);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	// aerial perspective by the true distance, thinner over the high ground
	float dist = length(p - CAMERA_POSITION_WORLD);
	float height = max(0.0, (p.y + CAMERA_POSITION_WORLD.y) * 0.5 - 60.0);
	float density = haze_density * 0.85 * exp(-height / 480.0);
	float haze = 1.0 - exp(-dist * density);
	FOG = vec4(haze_color, haze);
}
