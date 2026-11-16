shader_type spatial;
// The castle clock tower's faces (CastleExterior._clock_tower): the painted
// dial (assets/maps/grounds/clock_dial.png, tools/art/clock_dial.py) cut out
// round at its iron bezel, and the two hands drawn here from the realm's hour
// (`hour`, 0-24, DayNight.hour(): GMT+3 or the pinned hour), so every face
// tells the time the sky shows. At night the enamel glows from behind
// (`glow`, from GroundsMap.apply_daylight); the hands and the numerals stay
// dark against it. QuadMesh-style UV: x across the face, y = 0 at the top.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D dial : source_color, filter_linear_mipmap_anisotropic;
uniform float hour = 12.0;
uniform float glow = 0.1;
uniform vec3 glow_color : source_color = vec3(1.0, 0.86, 0.55);

// A hand along direction `a` (radians clockwise from twelve): a tapered blade
// from -tail to len with a lozenge at `loz` (start, end, half-width).
// Returns the signed distance (negative inside), in dial radii.
float hand(vec2 q, float a, float len, float tail, float w0, float w1, vec3 loz) {
	vec2 d = vec2(sin(a), cos(a));
	vec2 n = vec2(d.y, -d.x);
	float along = dot(q, d);
	float across = abs(dot(q, n));
	float t = clamp((along + tail) / (len + tail), 0.0, 1.0);
	float w = mix(w0, w1, t);
	// the lozenge: a diamond swelling between loz.x and loz.y
	float lt = clamp((along - loz.x) / max(loz.y - loz.x, 1e-4), 0.0, 1.0);
	float swell = loz.z * (1.0 - abs(lt * 2.0 - 1.0)) * step(loz.x, along) * step(along, loz.y);
	w = max(w, swell);
	// a pointed tip over the last 6 %
	w *= smoothstep(len, len - 0.06, along);
	float side = across - w;
	float ends = max(-tail - along, along - len);
	return max(side, ends);
}

void fragment() {
	vec2 q = (UV - 0.5) * 2.0;
	q.y = -q.y;
	float r = length(q);
	// round dial: the stone plaque behind shows outside the bezel
	if (r > 1.0) {
		discard;
	}
	vec4 painted = texture(dial, UV);
	float h12 = mod(hour, 12.0);
	float a_hour = h12 / 12.0 * TAU;
	float a_min = fract(hour) * TAU;
	float aa = max(fwidth(r), 0.002);
	float d_hour = hand(q, a_hour, 0.5, 0.13, 0.042, 0.022, vec3(0.32, 0.46, 0.07));
	float d_min = hand(q, a_min, 0.82, 0.18, 0.03, 0.014, vec3(0.6, 0.74, 0.045));
	float d_boss = r - 0.055;
	float d = min(min(d_hour, d_min), d_boss);
	float iron = 1.0 - smoothstep(-aa, aa, d);
	// the hands' shadow on the enamel (lit from the upper left)
	vec2 qs = q + vec2(-0.018, 0.022);
	float ds = min(min(hand(qs, a_hour, 0.5, 0.13, 0.042, 0.022, vec3(0.32, 0.46, 0.07)),
		hand(qs, a_min, 0.82, 0.18, 0.03, 0.014, vec3(0.6, 0.74, 0.045))), length(qs) - 0.055);
	float shadow = (1.0 - smoothstep(-0.01, 0.03, ds)) * (1.0 - iron);
	// a gilt rim on the hands and the boss's cap
	float rim = (1.0 - smoothstep(0.0, aa * 2.5, abs(d + aa * 2.0))) * iron;
	float cap = 1.0 - smoothstep(0.022 - aa, 0.022 + aa, r);
	vec3 iron_col = vec3(0.045, 0.04, 0.038);
	vec3 gilt = vec3(0.62, 0.47, 0.2);
	vec3 col = painted.rgb * (1.0 - shadow * 0.35);
	col = mix(col, iron_col, iron);
	col = mix(col, gilt, max(rim * 0.6, cap));
	ALBEDO = col;
	float metal = max(iron, smoothstep(0.91, 0.925, r));
	METALLIC = metal * 0.3;
	ROUGHNESS = mix(0.62, 0.42, metal);
	// lit from behind: only the enamel, never the ink, the iron or the hands
	EMISSION = glow_color * painted.rgb * painted.a * (1.0 - iron) * (1.0 - shadow * 0.5) * glow;
}
