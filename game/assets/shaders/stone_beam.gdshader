// A Dark Shard's (any stone's) light rising into the sky (StoneView): a soft
// shaft of its glow standing on the stone's crown, no tube and no edge. One
// quad turned about the upright axis to face the eye; across it a luminous
// core and a wide haze, and three layers of the erosion cloud (the spells'
// noise map) climbing through them at different speeds: the big one bends
// the core and shoves the sides in and out, the small one (winding a little
// as it climbs) eats the haze away into wisps, so it smoulders upward rather
// than standing ruled. It is white-hot in its heart and brightest where it
// leaves the crown (a soft bloom round it, painted: the low preset draws no
// glow pass), thins with height and is gone long before the quad ends.
//
// Premultiplied: by night it is light added to the dark; by day the haze
// also veils the sky behind it in its colour (`cover`), so a green shaft
// reads green against a bright sky instead of washing out to white. It is
// never narrower on screen than `min_px` pixels (widened and a little dimmed
// far off), and fuller and stronger from afar, so a stone across a valley
// still shows a column of light.
// `flare` (per stone) is a wave's or a landing's surge: brighter, reaching
// higher. With `tail` it is the falling stone's comet tail instead: brightest
// just over the stone, narrowing to nothing above it, streaming fast.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 colour : source_color = vec4(0.35, 1.0, 0.45, 1.0);
uniform sampler2D erosion : repeat_enable, filter_linear_mipmap, hint_default_white;
// metres the quad stands (the light is gone well before its top)
uniform float height = 160.0;
// the shaft's half width (m) once it has left the crown
uniform float radius = 2.2;
// its width leaving the crown, and at the quad's top, over `radius`
uniform float neck = 0.5;
uniform float taper = 1.6;
// metres over which the light falls to a third
uniform float falloff = 38.0;
// how fast the haze climbs (m/s)
uniform float rise = 2.4;
uniform float strength = 1.0;
uniform float cover = 0.72;
uniform float min_px = 13.0;
// the crown's painted bloom
uniform float bloom = 0.35;
uniform bool tail = false;
instance uniform float flare = 0.0;

varying vec2 v_m;      // x: metres across from the axis, y: metres over the foot
varying float v_w;     // the half width drawn here (m)
varying float v_dim;   // < 1 where it was widened for distance
varying float v_near;  // fades out as the eye comes into it
varying float v_far;   // 0 near, 1 from ~120 m: fuller and stronger, to be found

// the quad's half width over the shaft's, and how far it reaches under the
// foot (the crown's bloom is round, and must not be cut by the quad's end)
const float SPREAD = 2.4;

void vertex() {
	vec3 foot = MODEL_MATRIX[3].xyz;
	float t = VERTEX.y;
	float below = tail ? 0.0 : radius * 1.2;
	float h = mix(-below, height, t);
	float up = clamp(h / height, 0.0, 1.0);
	vec3 to_eye = CAMERA_POSITION_WORLD - foot;
	vec2 flat_eye = to_eye.xz;
	float reach = length(flat_eye);
	flat_eye = reach > 0.001 ? flat_eye / reach : vec2(0.0, 1.0);
	vec3 across = vec3(flat_eye.y, 0.0, -flat_eye.x);
	float w;
	if (tail) {
		w = radius * (pow(1.0 - up, 0.85) + 0.03);
	} else {
		w = radius * mix(neck, 1.0, smoothstep(0.0, radius * 4.0, h)) * mix(1.0, taper, up);
	}
	vec3 at = foot + vec3(0.0, h, 0.0);
	float dist = length(CAMERA_POSITION_WORLD - at);
	float pixel = dist * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float drawn = max(w, pixel * min_px * 0.5);
	v_dim = mix(1.0, w / drawn, 0.3);
	v_far = smoothstep(20.0, 120.0, dist);
	v_w = drawn;
	// a slow sway that grows with height, so the shaft never stands ruled
	float sway = tail ? 0.0 : sin(h * 0.045 - TIME * 0.25) * clamp(h * 0.012, 0.0, 1.0) * radius * 0.4;
	float x = VERTEX.x * 2.0 * drawn * SPREAD;
	v_m = vec2(x, h);
	v_near = smoothstep(1.0, 5.0, reach);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(at + across * (x + sway), 1.0);
}

void fragment() {
	float h = v_m.y;
	float x = v_m.x / v_w;
	float scroll = TIME * (tail ? 30.0 : rise);
	float big = radius * 11.0;
	float small = radius * 4.5;
	float n1 = texture(erosion, vec2(x * 0.1 + 0.13, (h - scroll) / big)).r;
	// the wisps wind about the shaft as they climb
	float twist = sin(h / (radius * 4.0) - TIME * 0.7) * 0.12;
	float n2 = texture(erosion, vec2(x * 0.24 + 0.61 + twist, (h - scroll * 1.5) / small)).r;
	float n3 = texture(erosion, vec2(x * 0.06 + 0.37, (h - scroll * 0.6) / (big * 2.3))).r;
	// the big cloud shoves the sides about and bends the core
	float xw = x + (n1 - 0.5) * 0.8;
	// the core: a smooth luminous band, its brightness drifting up it
	float core = exp(-xw * xw * mix(3.2, 1.9, v_far)) * (0.5 + 0.7 * n3);
	// the haze round it: wide and dim, the small cloud eating it into wisps
	float wide = exp(-xw * xw * 0.9);
	float wisps = smoothstep(0.0, 0.85, wide + (n2 - 0.55) * 0.7) * wide * (0.6 + 0.6 * n1);
	// nothing reaches the quad's sides
	float sides = 1.0 - smoothstep(SPREAD * 0.65, SPREAD, abs(x));
	float surge = clamp(flare, 0.0, 1.5);
	float reach = falloff * (1.0 + surge * 1.4);
	float env;
	if (tail) {
		env = smoothstep(0.0, 1.2, h) * pow(1.0 - clamp(h / height, 0.0, 1.0), 1.6);
	} else {
		env = smoothstep(0.0, radius * 1.6, h)
			* (exp(-h * 1.1 / reach) * 0.8 + exp(-h * 0.35 / reach) * 0.2)
			* (1.0 - smoothstep(height * 0.5, height * 0.95, h));
	}
	float breath = 0.9 + 0.1 * sin(TIME * 2.1);
	float gain = strength * breath * (1.0 + surge) * v_dim * v_near * sides * (1.0 + 0.45 * v_far);
	// the painted bloom round the crown, broken by the same cloud
	float bx = x * v_w;
	float by = h - radius * 0.35;
	float crown = tail ? 0.0 : exp(-(bx * bx + by * by) / (radius * radius * 0.42)) * bloom * (0.7 + 0.3 * n2);
	float shaft = (core * 0.45 + wisps * 0.2) * env;
	// white-hot in its heart near the crown, its own colour outward and up
	float heat = exp(-xw * xw * 9.0) * env * (1.0 - smoothstep(0.0, reach * 1.5, h));
	vec3 hot = mix(colour.rgb, vec3(1.0), clamp(heat * 0.35 + crown * 0.2, 0.0, 0.4));
	ALBEDO = hot * (shaft + crown) * gain;
	ALPHA = clamp(((core * 0.6 + wisps * 0.5) * env + crown * 0.4) * cover * v_near * sides * (1.0 + surge * 0.4 + v_far * 0.35), 0.0, 0.85);
}
