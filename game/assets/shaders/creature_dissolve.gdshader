shader_type spatial;
// A fallen creature burning away (CreatureView): its own surface (the
// imported StandardMaterial3D's albedo, normal, roughness, metal and glow,
// copied in by CreatureView) eaten by a front of 3D value noise in the body's
// own space, the parts highest up first. Just ahead of the front the surface
// chars dark; on the front it glows as embers (white-hot at the very edge,
// cooling to deep red) that flicker. Fragments behind the front are
// discarded, so it stays an opaque draw (no sorting) and its shadow burns
// away with it. `dissolve` is per body (instance uniform): one material per
// source material serves every dying creature at its own pace.
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale = 1.0;
uniform float roughness = 1.0;
uniform sampler2D roughness_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 roughness_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform float metallic = 0.0;
uniform sampler2D metallic_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 metallic_channel = vec4(0.0, 0.0, 1.0, 0.0);
uniform float specular = 0.5;
uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform sampler2D emission_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 uv1_scale = vec3(1.0);
uniform vec3 uv1_offset = vec3(0.0);

// 0: whole, 1: gone.
instance uniform float dissolve = 0.0;
// The ember colours (white-hot edge -> deep glow).
uniform vec3 ember_hot : source_color = vec3(1.0, 0.78, 0.42);
uniform vec3 ember_deep : source_color = vec3(0.95, 0.22, 0.04);
uniform float ember_energy = 7.0;
// Width of the glowing front and of the charred band ahead of it (noise units).
uniform float edge = 0.035;
uniform float char_band = 0.1;
// Noise cells per metre, and how much higher parts go first.
uniform float noise_scale = 5.0;
uniform float height_bias = 0.25;

varying vec3 body_pos;

float hash3(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), f.x),
			mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), f.x),
			mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	UV = UV * uv1_scale.xy + uv1_offset.xy;
	// metres from the body's own origin, in the world's orientation: the
	// pattern stays on the corpse (it no longer moves) whatever the rig scale
	body_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz - NODE_POSITION_WORLD;
}

void fragment() {
	vec3 p = body_pos * noise_scale;
	float n = value_noise(p) * 0.6 + value_noise(p * 2.13 + 7.1) * 0.28 + value_noise(p * 4.7 + 3.3) * 0.12;
	// fbm bunches round 0.5: spread it so the front eats the body steadily
	n = smoothstep(0.22, 0.78, n);
	// higher up burns first
	float h = clamp(body_pos.y * 0.5, 0.0, 1.0);
	float v = clamp(mix(n, 1.0 - h, height_bias), 0.0, 1.0);
	// the front sweeps v from below 0 (nothing gone) to past 1 (all gone)
	float front = dissolve * (1.0 + edge + char_band) - edge;
	float d = v - front;
	if (d < 0.0) {
		discard;
	}
	float on = step(0.0005, dissolve);
	float glow = (1.0 - smoothstep(0.0, edge, d)) * on;
	float charred = (1.0 - smoothstep(edge, edge + char_band, d)) * on;
	vec4 base = texture(albedo_tex, UV) * albedo;
	ALBEDO = base.rgb * mix(1.0, 0.06, charred * charred);
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
	ROUGHNESS = mix(roughness * dot(texture(roughness_tex, UV), roughness_channel), 1.0, charred);
	METALLIC = metallic * dot(texture(metallic_tex, UV), metallic_channel) * (1.0 - charred);
	SPECULAR = specular;
	float flicker = 0.75 + 0.25 * sin(TIME * 17.0 + n * 40.0);
	vec3 ember = mix(ember_deep, ember_hot, glow * glow);
	EMISSION = emission * emission_energy * texture(emission_tex, UV).rgb * (1.0 - charred)
		+ ember * glow * glow * ember_energy * flicker;
}
