shader_type spatial;
// The dungeons' stone, rock and timber (maps/dng_common/dungeon_view.gd): one
// PBR set made into a place that has been lived in, abandoned and left damp.
// Everything past the base set comes from noise, never from drawn lines:
//
//   second set   a second PBR set laid through the first by a low-frequency
//                noise mask (worn flags into packed dirt, cut blocks into
//                rubble masonry): one floor no longer repeats one tile
//   macro        broad noise patches lighten and darken the stone (and shift
//                its hue a little), so a long wall reads as many stones
//   grime        the foot of every wall darkened and dulled where dirt and
//                damp climb, its upper edge torn by the noise
//   streaks      seep stains running down the walls (noise stretched along
//                the fall)
//   moss         damp growth on what faces up and on the wall's foot, where
//                the noise lets it take hold
//   worn edges   on dressed trim (BoxMesh pieces: their 3 x 2 face layout
//                gives each face's extent), the arrises lightened and
//                chipped back by the noise
//
// Mapping: 0 = world triplanar on the dominant axis (the boxes, which have
// no art-directed UVs); 1 = the mesh's own UVs in metres x uv_scale (vaults,
// rock skins and ceilings: curved surfaces where switching the projection
// axis would draw a seam), normal-mapped through the mesh's tangents.
//
// Low-preset cost: albedo + normal (+ the second set's two where it is on)
// + two noise reads; no roughness or AO maps.

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 tint : source_color = vec3(1.0);
uniform float world_scale = 0.3;
uniform float normal_strength : hint_range(0.0, 3.0) = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.86;

uniform int mapping = 0;
uniform float uv_scale = 0.3;

uniform bool use_second = false;
uniform sampler2D albedo2_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal2_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 tint2 : source_color = vec3(1.0);
uniform float world_scale2 = 0.3;
// share of the surface the second set takes, and how soft its border is
uniform float second_cover : hint_range(0.0, 1.0) = 0.35;
uniform float second_soft : hint_range(0.01, 0.5) = 0.2;
uniform float second_metres = 9.0;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float macro_metres = 7.0;
uniform float macro_amount : hint_range(0.0, 1.0) = 0.28;
uniform float macro_hue : hint_range(0.0, 1.0) = 0.08;

uniform float floor_y = 0.0;
uniform float grime_height = 1.6;
uniform float grime_amount : hint_range(0.0, 1.0) = 0.55;
uniform vec3 grime_color : source_color = vec3(0.16, 0.13, 0.1);
uniform float streak_amount : hint_range(0.0, 1.0) = 0.3;

uniform vec3 moss_color : source_color = vec3(0.2, 0.24, 0.12);
uniform float moss_amount : hint_range(0.0, 1.0) = 0.0;
uniform float moss_height = 1.0;

uniform float edge_wear : hint_range(0.0, 1.0) = 0.0;
uniform float wear_width = 0.06;

varying vec3 world_pos;
varying vec3 world_nrm;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

vec3 tangent_normal(sampler2D tex, vec2 uv) {
	vec3 tn;
	// RG normal maps sample blue as 0: rebuild z
	tn.xy = texture(tex, uv).xy * 2.0 - 1.0;
	tn.z = sqrt(max(1.0 - dot(tn.xy, tn.xy), 0.0));
	tn.xy *= normal_strength;
	return normalize(tn);
}

float noise_at(vec2 p) {
	return texture(noise_tex, p).r;
}

void fragment() {
	vec3 n = normalize(world_nrm);
	vec3 an = abs(n);
	vec2 plane;   // metres on the surface (for the noise masks)
	vec3 t = vec3(1.0, 0.0, 0.0);
	vec3 b = vec3(0.0, 0.0, 1.0);
	if (mapping == 1) {
		plane = UV;
	} else if (an.y >= an.x && an.y >= an.z) {
		plane = world_pos.xz;
	} else if (an.x >= an.z) {
		plane = world_pos.zy;
		t = vec3(0.0, 0.0, 1.0);
		b = vec3(0.0, 1.0, 0.0);
	} else {
		plane = world_pos.xy;
		b = vec3(0.0, 1.0, 0.0);
	}
	vec2 uv = mapping == 1 ? UV * uv_scale : plane * world_scale;
	vec3 albedo = texture(albedo_tex, uv).rgb * tint;
	vec3 tn = tangent_normal(normal_tex, uv);

	// the second set, through a low-frequency noise mask
	float m_low = noise_at(plane / second_metres + vec2(0.37, 0.11));
	if (use_second) {
		float k = smoothstep(1.0 - second_cover - second_soft, 1.0 - second_cover + second_soft, m_low);
		vec2 uv2 = (mapping == 1 ? UV : plane) * world_scale2;
		albedo = mix(albedo, texture(albedo2_tex, uv2).rgb * tint2, k);
		tn = normalize(mix(tn, tangent_normal(normal2_tex, uv2), k));
	}

	// broad patches: brightness and a slight warm/cool drift
	float m_macro = noise_at(plane / macro_metres);
	float m_fine = noise_at(plane / (macro_metres * 0.23) + vec2(0.5, 0.21));
	albedo *= 1.0 + macro_amount * (m_macro - 0.5) * 2.0;
	albedo *= mix(vec3(1.0), vec3(1.06, 1.0, 0.92), macro_hue * (m_fine - 0.5) * 4.0);

	float rough = roughness;
	float h = world_pos.y - floor_y;
	bool vertical = an.y < 0.6;

	// worn arrises on dressed trim (BoxMesh faces: a 3 x 2 grid of the UV)
	if (edge_wear > 0.0 && mapping == 0) {
		vec2 g = UV * vec2(3.0, 2.0);
		vec2 f = fract(g);
		vec2 du = dFdx(UV);
		vec2 dv = dFdy(UV);
		float det = du.x * dv.y - du.y * dv.x;
		if (abs(det) > 1e-12) {
			vec3 dpx = dFdx(world_pos);
			vec3 dpy = dFdy(world_pos);
			vec3 dp_du = (dpx * dv.y - dpy * du.y) / det;
			vec3 dp_dv = (dpy * du.x - dpx * dv.x) / det;
			vec2 metres = vec2(length(dp_du) / 3.0, length(dp_dv) / 2.0);
			vec2 d = min(f, 1.0 - f) * metres;
			float edge = min(d.x, d.y);
			float chip = (m_fine - 0.5) * wear_width * 1.6;
			float wear = 1.0 - smoothstep(wear_width * 0.35, wear_width, edge + chip);
			albedo = mix(albedo, albedo * 1.35 + vec3(0.03), wear * edge_wear);
			tn = normalize(mix(tn, vec3(0.0, 0.0, 1.0), wear * edge_wear * 0.6));
			rough = mix(rough, 0.95, wear * edge_wear);
		}
	}

	// grime and damp climbing the foot of the walls, torn by the noise
	float rise = grime_height * (0.6 + 0.8 * m_fine);
	float grime = vertical ? 1.0 - smoothstep(0.0, rise, h) : 0.0;
	albedo = mix(albedo, albedo * grime_color * 2.2, grime * grime_amount);
	rough = mix(rough, 0.97, grime * 0.5);

	// seep stains: the noise stretched down the fall
	if (vertical && streak_amount > 0.0) {
		vec2 sp = vec2(dot(world_pos, vec3(1.0, 0.0, 1.0)) * 0.55, world_pos.y * 0.035);
		float s = noise_at(sp + vec2(0.13, 0.71));
		float stain = smoothstep(0.55, 0.85, s) * smoothstep(0.3, 0.7, m_macro);
		albedo *= 1.0 - stain * streak_amount;
	}

	// moss: on what faces up, and creeping up the wall's foot
	if (moss_amount > 0.0) {
		float up = smoothstep(0.55, 0.9, n.y);
		float foot = vertical ? 1.0 - smoothstep(0.0, moss_height * (0.5 + m_macro), h) : 0.0;
		float where = max(up * 0.75, foot);
		float m = smoothstep(0.5, 0.75, m_fine * 0.6 + m_macro * 0.4 + where * 0.35) * where;
		m *= moss_amount;
		vec3 moss = moss_color * (0.7 + 0.6 * m_fine);
		albedo = mix(albedo, moss, m);
		tn = normalize(mix(tn, vec3(0.0, 0.0, 1.0), m * 0.5));
		rough = mix(rough, 0.98, m);
	}

	ALBEDO = albedo;
	if (mapping == 1) {
		NORMAL_MAP = tn * 0.5 + 0.5;
		NORMAL_MAP_DEPTH = 1.0;
	} else {
		float handed = sign(dot(n, cross(t, b)));
		vec3 wn = normalize(tn.x * t + tn.y * b * handed + tn.z * n);
		NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	}
	ROUGHNESS = rough;
	METALLIC = 0.0;
}
