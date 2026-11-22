// The Broodclutch Stone's body (assets/models/monolith/broodclutch_stone.tscn):
// a heap of great spider eggs (`membrane`) sitting in one of the caverns'
// egg clutches (cavern_eggs.glb's maps), each lit faintly from within by the
// stone's glow. The glow is painted (the low preset draws no glow pass).
// The clutch's eggs glow in their dark veins and where a shell turns away
// from the eye (light through a thin shell); its silk (grey-white) stays
// unlit. A great egg is a wet, pale membrane mottled with the clutch's violet
// (the erosion cloud over it), a web of veins (the cloud's ridges) and the
// light inside showing through its thin rim. Each egg beats at its own time
// (COLOR.r is its own phase), so the clutch seems to stir.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D mr_tex : hint_default_white, filter_linear_mipmap;
uniform sampler2D cloud : repeat_enable, filter_linear_mipmap, hint_default_white;
// the stone's glow (creature_views.json `glow`)
uniform vec4 glow : source_color = vec4(1.0, 0.4, 0.82, 1.0);
uniform float energy = 0.6;
uniform bool membrane = false;
uniform vec3 shell : source_color = vec3(0.8, 0.72, 0.86);
uniform vec3 mottle : source_color = vec3(0.46, 0.3, 0.6);

varying vec3 local_pos;
varying float own_phase;

void vertex() {
	local_pos = VERTEX;
	own_phase = COLOR.r * 6.2831853;
}

void fragment() {
	float thin = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	if (membrane) {
		// UV.x round the egg (the cloud tiles, so the seam never shows), UV.y
		// from its top to its foot
		vec2 p = vec2(UV.x, UV.y * 0.6) + vec2(COLOR.r * 3.7, COLOR.r * 1.9);
		float c1 = texture(cloud, p).r;
		float c2 = texture(cloud, p * 1.7 + 0.41).r;
		float blotch = smoothstep(0.5, 0.85, c1 * 0.8 + c2 * 0.25);
		float vein = 1.0 - smoothstep(0.0, 0.035, abs(c2 - 0.5));
		vein *= smoothstep(0.35, 0.75, c1);
		vec3 base = mix(shell, mottle, blotch * 0.55);
		float beat = 0.5 + 0.5 * sin(TIME * 1.3 + own_phase);
		beat = beat * beat * (3.0 - 2.0 * beat);
		ALBEDO = mix(base, base * glow.rgb, 0.18) * (1.0 - vein * 0.35);
		ROUGHNESS = 0.32;
		SPECULAR = 0.55;
		float inner = thin * thin * (0.5 + 0.5 * blotch) + vein * 0.55;
		EMISSION = glow.rgb * (0.08 + 0.6 * beat) * inner * energy;
	} else {
		vec3 a = texture(albedo_tex, UV).rgb;
		// the clutch's eggs: their violet (red and blue over green); silk is grey
		float egg = clamp((min(a.r, a.b) - a.g) * 6.0, 0.0, 1.0);
		ALBEDO = mix(a, a * mix(vec3(1.0), glow.rgb, 0.35), egg);
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		vec4 mr = texture(mr_tex, UV);
		ROUGHNESS = mr.g;
		METALLIC = mr.b * 0.2;
		// a smooth field of phases over the clutch: every egg beats on its own
		float phase = sin(local_pos.x * 2.7 + 1.3) * 1.7 + sin(local_pos.z * 2.3 + local_pos.y * 1.9) * 1.6
			+ sin(local_pos.y * 3.1 - local_pos.x * 1.1) * 1.2;
		float beat = 0.5 + 0.5 * sin(TIME * 1.35 + phase);
		beat = beat * beat * (3.0 - 2.0 * beat);
		float veins = clamp((0.62 - dot(a, vec3(0.33))) * 2.5, 0.0, 1.0);
		EMISSION = glow.rgb * egg * (0.12 + 0.55 * beat) * (0.35 + 0.65 * thin * thin + veins * 0.6) * energy;
	}
}
