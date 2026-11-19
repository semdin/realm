shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

// Shardglass Ward's shell (WardShield with spell shardglass_ward): the ward
// surface's bright rim, blow ripples and erosion, with the dome broken into
// glass shards - a cellular (Worley) field over the dome whose borders are
// faint cracks, each shard a pane that catches the light on its own as the
// shell turns, the flow noise drifting through the glass.
uniform sampler2D flow_noise : repeat_enable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.55, 0.95, 0.85, 0.3);
uniform float clock = 0.0;
uniform float opacity = 1.0;
uniform float erode = 0.0;
uniform vec3 hit_point = vec3(0.0);
uniform float hit_age = 10.0;
// Shards round the dome (a whole number, so the cells meet at the seam) and up it.
uniform vec2 shard_scale = vec2(9.0, 5.0);
varying vec3 world_position;

vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

void vertex() { world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }

void fragment() {
	float rim = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.6);
	// the nearest and second-nearest seeds give each shard and its border
	vec2 uv = UV * shard_scale;
	vec2 cell = floor(uv);
	vec2 local = fract(uv);
	float f1 = 8.0;
	float f2 = 8.0;
	vec2 id = vec2(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 o = vec2(float(x), float(y));
			vec2 c = cell + o;
			vec2 wrapped = vec2(mod(c.x, shard_scale.x), c.y);
			vec2 seed = o + 0.075 + hash2(wrapped) * 0.85;
			float d = length(seed - local);
			if (d < f1) {
				f2 = f1;
				f1 = d;
				id = wrapped;
			} else if (d < f2) {
				f2 = d;
			}
		}
	}
	float noise = texture(flow_noise, UV * 3.0 + vec2(clock * 0.025, -clock * 0.04)).b;
	// cracks fade in and out along the flow noise, never a full drawn net
	float crack = (1.0 - smoothstep(0.02, 0.09, f2 - f1)) * smoothstep(0.3, 0.7, noise);
	// each pane glints as its facet turns past the light
	float glint = pow(0.5 + 0.5 * sin(clock * 1.7 + hash2(id + 3.1).x * 6.2831 + UV.x * 6.2831), 6.0);
	float face = 0.25 + 0.75 * hash2(id + 7.7).y;
	float dist = distance(world_position, hit_point);
	float ripple = exp(-pow((dist - hit_age * 5.0) / 0.12, 2.0)) * (1.0 - smoothstep(0.0, 0.55, hit_age));
	float dissolve = 1.0 - smoothstep(noise - 0.06, noise + 0.06, erode);
	float glass = face * (0.02 + 0.3 * glint) * (0.6 + 0.8 * noise);
	ALBEDO = mix(tint.rgb * 1.6, vec3(0.85, 1.0, 0.97), clamp(ripple + glint * 0.35, 0.0, 1.0));
	ALPHA = (rim * 0.42 + glass + crack * 0.16 + ripple * 0.85) * opacity * dissolve;
}
