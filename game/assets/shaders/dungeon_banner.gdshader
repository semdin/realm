shader_type spatial;
// A hanging cloth in the dungeons (maps/dng_common/dungeon_view.gd _banner):
// coarse woven hessian dyed in a house-neutral colour, the dye uneven and
// faded by noise, soot darkening the top, damp staining the foot, the hem
// frayed and torn away by noise (alpha scissor: an opaque draw), stirring a
// little in the draught. Plain cloth: no emblem, no glyph.

render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley;

uniform sampler2D weave_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D weave_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 dye : source_color = vec3(0.4, 0.38, 0.36);
uniform vec3 band : source_color = vec3(0.78, 0.72, 0.62);
// the plain band across the cloth near its foot (0 = none), as UV.y span
uniform vec2 band_at = vec2(0.78, 0.86);
uniform vec2 size = vec2(1.4, 3.6);
uniform float seed = 0.0;
uniform float sway = 0.05;
// 1 = hung from a rod (soot over the top, damp at the foot, a torn hem);
// 0 = laid on a floor as a runner (worn evenly, both ends frayed)
uniform float hang = 1.0;

// soft vertical folds hung from the rod (folds across the width)
uniform float folds = 3.0;
uniform float fold_depth = 0.06;

varying float fold_shade;

void vertex() {
	// UV.y 0 at the rod: the foot moves most
	float free = UV.y * UV.y;
	float t = TIME * 0.7 + seed * 13.0;
	float phase = UV.x * folds * 6.2832 + seed * 5.0 + sin(UV.y * 2.7 + seed * 3.0) * 0.8;
	float fold = sin(phase) * fold_depth * hang * (0.5 + 0.5 * UV.y);
	VERTEX.z += fold + (sin(t + UV.y * 2.3) * 0.6 + sin(t * 1.7 + UV.x * 3.1) * 0.4) * sway * free;
	VERTEX.x += sin(t * 0.8 + 1.3) * sway * 0.3 * free;
	// the fold's slope across the cloth: its side toward the light is lighter
	fold_shade = cos(phase) * hang * (0.5 + 0.5 * UV.y);
}

void fragment() {
	vec2 metres = UV * size;
	vec3 weave = texture(weave_tex, metres * 1.2).rgb;
	float lum = dot(weave, vec3(0.3, 0.59, 0.11));
	float n1 = texture(noise_tex, metres * 0.35 + vec2(seed, seed * 0.37)).r;
	float n2 = texture(noise_tex, metres * 1.3 + vec2(seed * 0.71, 0.2)).r;
	// the dye taken unevenly, a lighter band woven near the foot
	vec3 colour = dye * (0.75 + 0.5 * n1);
	// its edges wander with the weave, never a ruled line
	float by = UV.y + (n2 - 0.5) * 0.025;
	float in_band = smoothstep(band_at.x - 0.01, band_at.x + 0.015, by) * (1.0 - smoothstep(band_at.y - 0.015, band_at.y + 0.01, by));
	in_band *= step(0.001, band_at.y - band_at.x);
	colour = mix(colour, band * (0.8 + 0.3 * n2), in_band * 0.85);
	vec3 albedo = colour * (0.45 + lum * 1.3);
	// the folds: shade in their hollows, the selvedges darker and worn
	albedo *= 0.78 + 0.22 * fold_shade + 0.12;
	float edge = min(UV.x, 1.0 - UV.x) * size.x;
	albedo *= mix(0.72, 1.0, smoothstep(0.02, 0.09 + 0.04 * n2, edge));
	// faded where the dye ran thin, soot over the top, damp at the foot
	albedo = mix(albedo, vec3(lum * 0.7 + 0.15), smoothstep(0.55, 0.9, n2) * 0.35);
	albedo *= mix(1.0, mix(0.55, 1.0, smoothstep(0.0, 0.25 + 0.15 * n1, UV.y)), hang);
	albedo *= mix(1.0, 0.6, smoothstep(0.7, 1.0, UV.y) * n1 * hang);
	// worn pale where feet went (a runner's middle)
	albedo = mix(albedo, albedo * 1.25 + vec3(0.02), (1.0 - hang) * (1.0 - smoothstep(0.15, 0.4, abs(UV.x - 0.5))) * n2 * 0.6);
	// the frayed, torn hem and a few moth holes
	float hem = mix(1.0 - UV.y, min(UV.y, 1.0 - UV.y) * size.y * 0.2, 1.0 - hang);
	float torn = hem - (n2 * 0.09 + n1 * 0.06) + 0.02;
	float holes = smoothstep(0.86, 0.9, n2 * 0.6 + n1 * 0.4) * step(0.3, UV.y);
	ALPHA = step(0.0, torn) * (1.0 - holes);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALBEDO = albedo;
	vec3 tn;
	tn.xy = texture(weave_normal, metres * 1.2).xy * 2.0 - 1.0;
	tn.z = sqrt(max(1.0 - dot(tn.xy, tn.xy), 0.0));
	NORMAL_MAP = tn * 0.5 + 0.5;
	ROUGHNESS = 0.95;
}
