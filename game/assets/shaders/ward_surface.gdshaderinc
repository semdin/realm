// Ward Shield's shell (WardShield), shared by its two passes: the far side
// (ward_surface_back.gdshader, drawn first, its resting surface at half
// strength behind the hero; a blow's marks there at full strength)
// and the near side (ward_surface.gdshader). Two passes keep the blend in
// order; one double-sided pass drew the sides in triangle order and the shell
// came out faceted.
//   * surface: plasma filaments (the ridged, domain-warped veins of
//     ward_noise_512.png .b) flowing over the sphere on a slow warp field,
//     faint and clear across the face so the hero reads through it, stronger
//     toward the limb, where a soft fresnel band broken by a slow cloud
//     carries the shape; fine glints twinkle in the flow;
//   * raise (`bloom` 0 -> 1): the shell is woven outward from `bloom_dir`
//     (the wand), a hot ragged front sweeping round it;
//   * blows (`hits`, up to four): a flare at the point the blow met, a
//     noise-broken wave running out over the shell through the filaments and
//     a sprung dent in the surface; a perfect reflect (`hit_power` > 1.5)
//     flares white, runs a faster, stronger double wave and punches outward;
//   * end (`erode` 0 -> 1): it burns away along the erosion noise, a hot edge
//     on every hole.
// Glow is painted here (no glow post-process on the low preset): albedo
// stays near 1 and the blend is premultiplied - light added, and only the
// bright limb and flares cover a little of what is behind, so the shell keeps
// its colour over a bright sky while its face stays clear. No fog: with
// premultiplied blending fog would paint the whole sphere grey.
// The shell's space is the world's axes round its centre (the node is never
// rotated): `v_dir`, `hits` and `bloom_dir` are unit directions in it.

// R smooth fbm, G smoother fbm, B ridged filaments, A fine grain (all tile).
uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.25, 0.62, 1.0, 1.0);
uniform float clock = 0.0;
uniform float intensity = 1.0;
uniform float bloom = 1.0;
uniform vec3 bloom_dir = vec3(0.0, 0.0, -1.0);
uniform float erode = 0.0;
uniform float flash = 0.0;
// The caster's feet in the shell's unit space (y): the shell fades out into
// the ground there instead of being cut by it.
uniform float floor_local = -0.55;
// xyz the blow's direction from the centre, w its age in seconds (idle >= 9)
uniform vec4 hits[4];
uniform float hit_power[4];

varying vec3 v_dir;

// Triplanar round the sphere. The smooth channels blend; the filaments (.b)
// take the strongest projection instead (`ridge`, weighted by `k`), since
// three overlapping webs averaged together came out as a flat haze.
vec4 tri(vec3 p, vec3 w) {
	return texture(noise_tex, p.yz) * w.x + texture(noise_tex, p.zx) * w.y + texture(noise_tex, p.xy) * w.z;
}

vec4 tri_ridge(vec3 p, vec3 w, vec3 k, out float ridge) {
	vec4 x = texture(noise_tex, p.yz);
	vec4 y = texture(noise_tex, p.zx);
	vec4 z = texture(noise_tex, p.xy);
	ridge = max(x.b * k.x, max(y.b * k.y, z.b * k.z));
	return x * w.x + y * w.y + z * w.z;
}

void vertex() {
	vec3 d = normalize(VERTEX);
	v_dir = d;
	float push = 0.0;
	for (int i = 0; i < 4; i++) {
		float age = hits[i].w;
		if (age < 1.0) {
			float ang = acos(clamp(dot(d, hits[i].xyz), -1.0, 1.0));
			float reflect_hit = step(1.5, hit_power[i]);
			float shape = exp(-ang * ang / mix(0.2, 0.35, reflect_hit));
			float spring = exp(-age * 7.5) * cos(age * 27.0);
			push += mix(-0.075, 0.11, reflect_hit) * shape * spring;
		}
	}
	// a slow swell: the shell is held, not rigid
	push += 0.012 * sin(clock * 2.3 + d.y * 4.0 + d.x * 3.0) + 0.008 * sin(clock * 3.1 - d.z * 5.0);
	VERTEX *= 1.0 + push;
}

void fragment() {
	vec3 d = normalize(v_dir);
	vec3 w = pow(abs(d), vec3(4.0));
	w /= (w.x + w.y + w.z);
	vec3 k = pow(abs(d), vec3(6.0));
	k /= max(k.x, max(k.y, k.z));
	float t = clock;
	float fres = 1.0 - abs(dot(normalize(NORMAL), normalize(VIEW)));
	float broad = pow(fres, 1.4);

	// the flow: a slow warp, then two filament layers drifting across it
	vec4 a = tri(d * 0.42 + vec3(0.0, -t * 0.03, t * 0.017), w);
	vec3 warp = vec3(a.r - 0.5, a.g - 0.5, a.r - a.g) * 0.07;
	float ridge_b;
	float ridge_c;
	vec4 b = tri_ridge(d * 0.34 + warp + vec3(t * 0.022, -t * 0.045, 0.0), w, k, ridge_b);
	vec4 c = tri_ridge(d * 0.58 - warp * 1.3 + vec3(-t * 0.018, t * 0.035, -t * 0.04), w, k, ridge_c);
	// each filament a hot core in a soft glow, slow pulses running along the
	// web, brighter where the two layers cross
	float core_a = smoothstep(0.6, 1.0, ridge_b);
	float glow_a = smoothstep(0.2, 0.92, ridge_b);
	float core_b = smoothstep(0.68, 1.0, ridge_c);
	float glow_b = smoothstep(0.3, 0.95, ridge_c);
	float pulse = 0.5 + 0.5 * sin(t * 2.2 - a.r * 9.0 + a.g * 5.0);
	float veins = (core_a * 0.75 + glow_a * glow_a * 0.3) * (0.45 + 0.8 * pulse)
		+ core_b * 0.4 + glow_b * glow_b * 0.15 + core_a * core_b * 0.9;
	float glint = smoothstep(0.9, 1.0, c.a) * (0.5 + 0.5 * sin(t * 9.0 + b.a * 40.0)) * smoothstep(0.35, 0.8, ridge_b);

	// the limb: a soft band, not a drawn outline - broken by the slow cloud
	// and eased off at the very silhouette
	float limb = pow(fres, 3.0) * (1.0 - 0.55 * pow(fres, 14.0)) * (0.3 + 0.9 * a.r + 0.7 * veins) * 0.7;
	float flow = veins * (0.4 + 0.8 * broad) * (0.6 + 0.8 * a.g);
	float haze = 0.004 + broad * 0.05;
	float light = (haze + limb + flow + glint * (0.3 + 0.5 * broad)) * intensity;
	light *= (1.0 + flash * (0.35 + 1.1 * veins)) * SIDE_STRENGTH;
	float occl = (limb * 0.42 + flow * 0.12) * SIDE_STRENGTH;

	// a flash (a blow, the raise settling, a reflect) whitens the filaments
	float hot = flash * veins * 0.15;
	// blows
	for (int i = 0; i < 4; i++) {
		float age = hits[i].w;
		if (age < 1.0) {
			float p = hit_power[i];
			float reflect_hit = step(1.5, p);
			float ang = acos(clamp(dot(d, hits[i].xyz), -1.0, 1.0));
			float jag = (b.r - 0.5) * 0.3 + (c.a - 0.5) * 0.08;
			float core = exp(-pow((ang + jag * 0.25) / mix(0.2, 0.15, reflect_hit), 2.0))
				* exp(-age * mix(9.0, 6.0, reflect_hit));
			float front = age * mix(4.0, 6.5, reflect_hit);
			float life = max(0.0, 1.0 - age / mix(0.6, 0.8, reflect_hit));
			float wave = exp(-pow((ang + jag - front) / mix(0.14, 0.18, reflect_hit), 2.0)) * life * life;
			// a perfect reflect's second, slower wave behind the first
			wave += reflect_hit * exp(-pow((ang + jag * 1.4 - age * 3.4) / 0.14, 2.0)) * life * 0.7;
			float local = exp(-pow(ang / 0.75, 2.0)) * exp(-age * 4.0);
			float glow = (wave * (0.7 + 1.6 * veins) + local * (0.35 + 1.2 * veins) * 0.85) * min(p, 1.8);
			hot += core * (0.75 + 0.5 * ridge_b) * p + wave * veins * 0.4 * reflect_hit;
			light += glow;
			occl += glow * 0.25;
		}
	}
	light += hot;
	occl += hot * 0.3;

	// raise: woven outward from the wand, a hot ragged front ahead of it
	if (bloom < 0.999) {
		float from_bloom = acos(clamp(dot(d, normalize(bloom_dir)), -1.0, 1.0)) / PI;
		float x = from_bloom + (c.r - 0.5) * 0.28 + (b.a - 0.5) * 0.06 - (bloom * 1.4 - 0.12);
		float revealed = 1.0 - smoothstep(-0.07, 0.0, x);
		float sweep = exp(-pow(x / 0.06, 2.0)) * (1.0 - smoothstep(0.82, 1.0, bloom)) * (0.4 + 1.2 * veins);
		light = light * revealed + sweep;
		occl = occl * revealed + sweep * 0.2;
		hot += sweep * 0.4;
	}

	// end: burned away along the erosion noise, a hot edge on every hole
	if (erode > 0.0) {
		float e = a.r * 0.45 + b.r * 0.35 + c.a * 0.12 + (0.5 + 0.5 * d.y) * 0.08;
		float thr = erode * 1.12 - 0.06;
		float alive = smoothstep(thr, thr + 0.035, e);
		float edge = exp(-pow((e - thr - 0.02) / 0.035, 2.0)) * (1.0 - smoothstep(0.85, 1.0, erode))
			* (0.7 + 0.9 * veins);
		// what is left dims as it goes, so the last of it is the burning edges
		light = light * alive * (1.0 - 0.55 * erode) + edge * 1.3;
		occl = occl * alive + edge * 0.2;
		hot += edge * 0.35;
	}

	// into the ground at the caster's feet, along a ragged line; and quieter
	// seen from inside (the camera zoomed in on its own hero), where the
	// whole view is shell
	float ground = smoothstep(floor_local - 0.02, floor_local + 0.3, d.y + (a.g - 0.5) * 0.12);
	float inside = 1.0 - smoothstep(0.9, 1.1, length(CAMERA_POSITION_WORLD - NODE_POSITION_WORLD) / length(MODEL_MATRIX[0].xyz));
	ground *= 1.0 - 0.55 * inside;
	light *= ground;
	occl *= ground;

	vec3 deep = tint.rgb * vec3(0.3, 0.5, 0.85);
	vec3 col = mix(deep, tint.rgb, smoothstep(0.0, 0.25, light));
	col = mix(col, mix(tint.rgb, vec3(1.0), 0.4), smoothstep(0.5, 1.4, light));
	col = mix(col, vec3(1.0), smoothstep(0.35, 1.2, hot));
	ALBEDO = min(col * light, vec3(1.1));
	ALPHA = clamp(occl, 0.0, 0.85);
}
