shader_type spatial;
// The hero's face and neck (Face_Head, tools/art/hero/build_head.py): the
// MakeHuman photo skin (CC0) on its own head, a light and a dark skin of the
// same layout blended by the look's skin tone, the photo's fine shading as a
// detail normal, and the zone map (head_zones.png: G oily zones, B redness,
// A the scalp MakeHuman grows hair on; R, the beard area, is unused).
// Light: the same model as hero_skin.gdshader (per-channel wrap, the red
// channel seeing a blurred normal; two GGX lobes), so the face and the bare
// arms shade alike. Close up a tiling pore normal (skin_micro, CC BY 4.0)
// adds detail; further out it is not sampled.

#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D albedo_dark_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D zones_tex : hint_default_black, filter_linear_mipmap;
uniform sampler2D grain_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D micro_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
// the worn style's hair cap (hair_cards.py cap_<style>.png): R short-hair
// strands drawn along the style's flow, G their shade, B the hair's shadow on
// the scalp; one head material per style
uniform sampler2D cap_tex : hint_default_black, filter_linear_mipmap_anisotropic;
uniform bool has_cap = false;
uniform bool has_micro = false;
// mean linear luminance of the two skins (build_head.py prints them)
uniform float light_mean = 0.316;
uniform float dark_mean = 0.0295;
uniform float roughness : hint_range(0.0, 1.0) = 0.6;
uniform float oily_roughness : hint_range(0.0, 1.0) = 0.42;
uniform float detail_strength = 0.6;
uniform float grain_scale = 14.0;
uniform float micro_scale = 48.0;
uniform float micro_strength = 0.3;
uniform vec3 skin_wrap = vec3(0.24, 0.12, 0.08);

varying vec3 soft_normal;

void fragment() {
	float lt = dot(skin_tint, vec3(0.2126, 0.7152, 0.0722));
	float dark = smoothstep(0.42, 0.1, lt);
	vec3 tex = texture(albedo_tex, UV).rgb;
	if (dark > 0.001) {
		tex = mix(tex, texture(albedo_dark_tex, UV).rgb, dark);
	}
	// the tone's brightness from the palette, its hue a little
	float tex_mean = mix(light_mean, dark_mean, dark);
	vec3 hue = skin_tint / max(lt, 0.001);
	vec3 skin = tex * (light_mean * lt / tex_mean) * mix(vec3(1.0), hue, 0.3);
	vec4 zone = texture(zones_tex, UV);
	float grain = texture(grain_tex, UV * grain_scale).r;
	float strokes = texture(grain_tex, UV * vec2(grain_scale * 3.0, grain_scale * 0.6)).r;
	// redness: cheeks, nose tip, ears a touch warmer
	skin *= mix(vec3(1.0), vec3(1.04, 0.95, 0.94), zone.b * 0.6);
	float rough = mix(roughness, oily_roughness, zone.g);
	// under a hairstyle: the scalp in the hair's shadow, its short hairs on it
	vec3 colour = skin;
	float scalp = 0.0;
	if (has_cap) {
		vec3 cap = texture(cap_tex, UV).rgb;
		colour *= mix(vec3(1.0), vec3(0.72, 0.68, 0.68), cap.b);
		scalp = cap.r;
		vec3 short_hair = min(hair_color * mix(0.55, 1.1, cap.g), vec3(0.75));
		colour = mix(colour, short_hair, clamp(scalp * 1.15, 0.0, 1.0));
	}
	rough = mix(rough, 0.8, scalp);
	ALBEDO = colour;
	ROUGHNESS = rough;
	SPECULAR = 0.42;
	vec3 nm = texture(normal_tex, UV).rgb;
	nm.xy = (nm.xy - 0.5) * detail_strength + 0.5;
	soft_normal = NORMAL;
	float near = has_micro ? 1.0 - smoothstep(1.0, 2.2, -VERTEX.z) : 0.0;
	if (near > 0.0) {
		vec3 micro = texture(micro_tex, UV * micro_scale).rgb;
		nm.xy += (micro.xy - 0.5) * micro_strength * near;
		AO = mix(1.0, micro.b, 0.15 * near);
		AO_LIGHT_AFFECT = 0.0;
	}
	NORMAL_MAP = nm;
}

float ggx(float n_dot_h, float n_dot_l, float n_dot_v, float alpha) {
	float a2 = alpha * alpha;
	float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
	float vis = 0.5 / mix(2.0 * n_dot_l * n_dot_v, n_dot_l + n_dot_v, alpha);
	return a2 / (PI * d * d) * vis;
}

void light() {
	vec3 n_mid = normalize(soft_normal + NORMAL);
	vec3 n_dot_l = vec3(dot(soft_normal, LIGHT), dot(n_mid, LIGHT), dot(NORMAL, LIGHT));
	vec3 diffuse = clamp((n_dot_l + skin_wrap) / (1.0 + skin_wrap), 0.0, 1.0);
	vec3 shadow = vec3(sqrt(ATTENUATION), ATTENUATION, ATTENUATION * ATTENUATION);
	shadow = mix(vec3(ATTENUATION), shadow, 0.5);
	DIFFUSE_LIGHT += diffuse * shadow * LIGHT_COLOR / PI;
	float nl = clamp(n_dot_l.b, 0.0, 1.0);
	if (nl > 0.0) {
		vec3 h = normalize(VIEW + LIGHT);
		float nh = clamp(dot(NORMAL, h), 0.0, 1.0);
		float nv = clamp(dot(NORMAL, VIEW), 1e-3, 1.0);
		float alpha = ROUGHNESS * ROUGHNESS;
		float lobes = mix(ggx(nh, nl, nv, min(alpha + 0.3, 1.0)), ggx(nh, nl, nv, alpha), 0.6);
		float lh = clamp(dot(LIGHT, h), 0.0, 1.0);
		float f = 0.028 + 0.972 * pow(1.0 - lh, 5.0);
		SPECULAR_LIGHT += lobes * f * nl * ATTENUATION * LIGHT_COLOR * SPECULAR_AMOUNT;
	}
}
