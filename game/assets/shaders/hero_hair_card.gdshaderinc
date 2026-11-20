// Hair cards (tools/art/hero/hair_cards.py) and the face's brows and lashes.
// Shared by hero_hair_card.gdshader (the opaque pass: alpha cut, depth,
// strand-shaped shadows) and hero_hair_fringe.gdshader (the soft fringe the
// cut leaves out, blended over it: the edge anti-aliasing a TAA or MSAA would
// give, which this game runs without).
//
// Card data (hair_cards.py): the atlas holds R strand id, G depth inside the
// clump (0 under .. 1 on top), A coverage; UV2.x runs root 0 .. tip 1 along the
// card, UV2.y is the card's layer (0 against the scalp .. 1 outermost);
// COLOR.r a random per card, COLOR.g how far its tip may swing (length),
// COLOR.b the baked occlusion (head and inner layers). The normals point out
// of the head (bent), so the hair lights as one volume, not as flat cards.
// Brows and lashes (MakeHuman cards) carry none of that: use_card_data off.
//
// Light: Kajiya-Kay along the strand with two shifted lobes (Scheuermann's
// R and TRT: a white highlight toward the root, a coloured, sparkling one
// toward the tip), a wrapped diffuse and transmission when lit from behind.

#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D atlas_tex : source_color, filter_linear_mipmap_anisotropic;
uniform bool use_card_data = true;
// the strands run along the texture's U (MakeHuman brows) instead of V
uniform bool strand_along_u = false;
uniform float alpha_cut = 0.5;
// thin strands vanish in the far mips: coverage grows with the mip level
uniform float mip_coverage = 0.28;
uniform float darkness = 1.0;
uniform float root_dark = 0.7;
uniform float shift_r = -0.12;
uniform float shift_trt = 0.18;
uniform float gloss_r = 260.0;
uniform float gloss_trt = 50.0;
uniform float spec_r = 0.065;
uniform float spec_trt = 0.22;
uniform float transmit = 0.3;
uniform float sway_scale = 1.0;
uniform float wind_scale = 0.004;
uniform float fringe_far = 14.0;
// per strand the highlights slide along it by up to this (the strand id):
// one shift for a whole card read as a flat plastic sheen
uniform float shift_jitter = 0.06;

varying vec3 strand_dir;
varying float strand_ao;
varying float sparkle;
varying float strand_shift;

void vertex() {
	if (use_card_data) {
		float t = UV2.x;
		float flex = t * sqrt(t) * COLOR.g * sway_scale;
		float phase = TIME * 2.3 + COLOR.r * 6.283;
		vec3 off = hair_sway.xyz * flex;
		off += vec3(sin(phase), 0.0, cos(phase * 0.8)) * hair_sway.w * wind_scale * flex;
		// world -> model (rotation and a near-uniform scale: transpose)
		vec3 off_m = (vec4(off, 0.0) * MODEL_MATRIX).xyz;
		// never into the head: the normals point out of the skull
		float inward = dot(off_m, NORMAL);
		off_m -= NORMAL * min(inward, 0.0);
		VERTEX += off_m;
	}
}

float coverage_at(vec2 uv, float a) {
	float lod = textureQueryLod(atlas_tex, uv).x;
	return a * (1.0 + max(lod, 0.0) * mip_coverage);
}

void hair_surface(vec2 uv, vec2 uv2, vec4 col, out vec3 albedo, out float coverage,
		out float ao, out float glint, out float jitter) {
	vec4 a = texture(atlas_tex, uv);
	coverage = coverage_at(uv, a.a);
	vec3 base = hair_color;
	if (use_card_data) {
		float id = a.r;
		float lock_crown = a.g;
		float t = uv2.x;
		// each lock shaded round (its crown light, its edges in its own
		// shadow), a soft root-to-tip gradient, strands only faintly apart
		float shade = mix(root_dark, 1.0, smoothstep(0.0, 0.4, t));
		shade *= mix(0.8, 1.0, lock_crown) * mix(0.9, 1.06, id) * mix(0.92, 1.0, col.r);
		// the outer layers a little lighter: sun-faded tops over a darker body
		shade *= mix(0.85, 1.08, uv2.y);
		albedo = base * shade * darkness;
		// depth: the inner layers sit in the hair's own shadow
		ao = mix(0.45, 1.0, uv2.y * uv2.y) * col.b * mix(0.85, 1.0, lock_crown);
		// highlights break into strands: some catch the light, most less
		// (a whole lock lit evenly read as a grey blob on dark hair)
		float g = fract(id * 7.31 + col.r * 3.7);
		glint = mix(0.12, 1.3, g * g) * mix(0.7, 1.0, lock_crown);
		// per strand only: one shift per card broke the band into patches
		jitter = (id - 0.5) * shift_jitter;
	} else {
		// MakeHuman brow / lash cards: their texture's shading on the hair colour
		float lum = dot(a.rgb, vec3(0.3, 0.59, 0.11));
		albedo = base * mix(0.55, 1.0, clamp(lum * 3.0, 0.0, 1.0)) * darkness;
		ao = 1.0;
		glint = 0.6;
		jitter = 0.0;
	}
	albedo = min(albedo, vec3(0.8));
}

void hair_light(vec3 t, float ao, float glint, float jitter, vec3 normal, vec3 view, vec3 light, vec3 light_color,
		float attenuation, float specular_amount, vec3 albedo, inout vec3 diffuse_light, inout vec3 specular_light) {
	// the strand along the hair's surface: a card's twist tilts its tangent
	// off the volume, and the highlight band broke where neighbours disagreed
	t = normalize(t - normal * dot(t, normal));
	float nl = dot(normal, light);
	float wrap = clamp((nl + 0.45) / 1.45, 0.0, 1.0);
	float tl = dot(t, light);
	float kk = sqrt(max(0.0, 1.0 - tl * tl));
	float diff = mix(wrap, kk * wrap, 0.35);
	diffuse_light += diff * attenuation * ao * light_color / PI;
	// transmission: light from behind the hair glows through its thin edges
	float back = pow(clamp(dot(-light, view), 0.0, 1.0), 5.0);
	diffuse_light += back * transmit * attenuation * light_color * (1.0 - 0.5 * ao) / PI;
	vec3 h = normalize(light + view);
	vec3 t1 = normalize(t + normal * (shift_r + jitter));
	vec3 t2 = normalize(t + normal * (shift_trt + jitter));
	float th1 = dot(t1, h);
	float th2 = dot(t2, h);
	float s1 = pow(max(0.0, 1.0 - th1 * th1), gloss_r * 0.5);
	float s2 = pow(max(0.0, 1.0 - th2 * th2), gloss_trt * 0.5);
	float facing = smoothstep(-0.2, 0.3, nl);
	// TRT leaves through the fibre's pigment: the hair's own colour, lifted
	vec3 tint = sqrt(albedo);
	// R is near white; a little of the hair's own colour keeps dark hair's
	// glints from reading as grey dust
	vec3 r_col = mix(vec3(1.0), tint / max(max(tint.r, max(tint.g, tint.b)), 0.05), 0.3);
	vec3 spec = r_col * (s1 * spec_r * glint) + tint * (s2 * spec_trt * (0.5 + 0.5 * glint));
	// the light's own specular share: the camera's character fill has none
	specular_light += spec * facing * attenuation * ao * light_color * specular_amount;
}
