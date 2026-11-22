shader_type particles;
// Ward Shield's motes (WardShield), drawn by ember_spark.gdshader (the
// particle's basis: X its radius, Y its motion streak). Local to the ward, so
// they ride with the caster. `mode`:
//   0  drifting: born on the shell, they slide round and up over its surface
//      and fade, a few at a time;
//   1  the raise: thrown from the wand side of the body out to the shell,
//      braking hard as they reach it, then drifting on it;
//   2  the end: shed off the breaking shell, outward and up, slowing and
//      cooling as they go.
// Never below the caster's feet (`floor_y`, local).
render_mode disable_velocity, disable_force;

uniform int mode = 0;
uniform float radius = 1.8;
uniform vec3 origin_dir = vec3(0.0, 0.0, -1.0);
uniform float size_min = 0.01;
uniform float size_max = 0.022;
uniform float stretch = 0.03;
uniform float floor_y = -1.0;
uniform float energy = 1.0;
uniform sampler2D ramp : repeat_disable, filter_linear;

uint step_rng(inout uint s) {
	s = s * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}

float rand(inout uint s) {
	return float(step_rng(s)) / 4294967295.0;
}

vec3 sphere_dir(inout uint s, float min_y) {
	float y = mix(min_y, 1.0, rand(s));
	float r = sqrt(max(0.0, 1.0 - y * y));
	float phi = rand(s) * 6.2831853;
	return vec3(r * cos(phi), y, r * sin(phi));
}

void start() {
	uint s = NUMBER * 9781u + RANDOM_SEED * 6271u + 17u;
	step_rng(s);
	CUSTOM.x = rand(s);
	CUSTOM.y = 0.0;
	CUSTOM.z = mix(size_min, size_max, pow(rand(s), 2.0));
	CUSTOM.w = mix(0.6, 1.0, rand(s));
	float min_y = clamp((floor_y + 0.3) / radius, -0.9, 0.5);
	vec3 d = sphere_dir(s, min_y);
	vec3 p = d * radius;
	vec3 v = vec3(0.0);
	if (mode == 1) {
		// thrown out of the wand side: the shell grows from there
		vec3 o = normalize(origin_dir);
		d = normalize(d + o * 0.9);
		d.y = max(d.y, min_y);
		d = normalize(d);
		p = o * 0.3 + (vec3(rand(s), rand(s), rand(s)) - 0.5) * 0.25;
		v = d;   // the direction it flies to (kept)
	} else if (mode == 2) {
		// born through the shell's thickness, not on one outline
		p = d * radius * mix(0.8, 1.04, rand(s));
		vec3 tangent = normalize(cross(d, vec3(0.0, 1.0, 0.0)) + vec3(0.0001));
		v = d * mix(0.5, 1.7, rand(s)) + vec3(0.0, mix(0.2, 0.7, rand(s)), 0.0)
			+ tangent * (rand(s) - 0.5) * 0.8;
	}
	TRANSFORM = mat4(1.0);
	TRANSFORM[3].xyz = p;
	VELOCITY = v;
	COLOR = vec4(0.0);
}

void process() {
	CUSTOM.y += DELTA / max(0.01, LIFETIME * CUSTOM.w);
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	}
	float age = clamp(CUSTOM.y, 0.0, 1.0);
	float seed = CUSTOM.x;
	vec3 p = TRANSFORM[3].xyz;
	vec3 before = p;
	float fade_in = 0.12;
	if (mode == 0) {
		// round and up over the surface
		float swirl = mix(0.25, 0.55, fract(seed * 7.13)) * (fract(seed * 3.7) > 0.5 ? 1.0 : -1.0);
		vec3 orbit = vec3(-p.z, 0.0, p.x) * swirl;
		p += (orbit + vec3(0.0, mix(0.12, 0.3, fract(seed * 5.3)), 0.0)) * DELTA;
		p = normalize(p) * radius * (1.0 + 0.015 * sin(TIME * 2.0 + seed * 20.0));
		fade_in = 0.25;
	} else if (mode == 1) {
		vec3 d = normalize(VELOCITY);
		vec3 o = normalize(origin_dir) * 0.3;
		float k = 1.0 - exp(-age * 9.0);
		vec3 target = d * radius;
		p = mix(o, target, k);
		// on arrival: a little drift round the shell
		p += vec3(-d.z, 0.0, d.x) * age * 0.12;
		p = mix(p, normalize(p) * radius, smoothstep(0.35, 0.6, age));
		fade_in = 0.02;
	} else {
		vec3 v = VELOCITY;
		v /= 1.0 + 2.2 * DELTA;
		v.y += 0.35 * DELTA;
		v += 0.6 * DELTA * vec3(sin(TIME * 5.0 + seed * 31.0), 0.0, cos(TIME * 4.3 + seed * 17.0));
		VELOCITY = v;
		p += v * DELTA;
		fade_in = 0.02;
	}
	p.y = max(p.y, floor_y + 0.05);
	vec3 motion = (p - before) / max(DELTA, 0.0001);
	float speed = length(motion);
	float r = CUSTOM.z;
	vec3 y = speed > 0.001 ? motion / speed : vec3(0.0, 1.0, 0.0);
	vec3 x = normalize(abs(y.y) < 0.99 ? cross(y, vec3(0.0, 1.0, 0.0)) : vec3(1.0, 0.0, 0.0));
	vec3 z = cross(x, y);
	TRANSFORM[0] = vec4(x * r, 0.0);
	TRANSFORM[1] = vec4(y * max(r, speed * stretch), 0.0);
	TRANSFORM[2] = vec4(z * r, 0.0);
	TRANSFORM[3] = vec4(p, 1.0);
	vec4 c = texture(ramp, vec2(age, 0.5));
	float envelope = smoothstep(0.0, fade_in, age) * (1.0 - smoothstep(0.6, 1.0, age));
	float twinkle = 0.7 + 0.3 * sin(TIME * 13.0 + seed * 57.0);
	COLOR = vec4(c.rgb * energy * twinkle, c.a * envelope);
}
