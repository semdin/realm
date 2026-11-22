shader_type particles;
// Motes of the level-up moment (LevelUpFX), drawn by ember_spark.gdshader like
// every spark in the game (the particle's basis carries its size and its
// streak). Two kinds, by `mode`:
//   0 shed  sparkle shed by the three comets winding up round the hero
//           (level_up_helix.gdshader: the same helix, the same `age`): born
//           just behind a comet's head, carried a little along its path,
//           then drifting up and winking out, so each comet leaves a trail
//           of glitter. Local coordinates: it stays round a hero who walks on.
//   1 skid  light thrown out over the ground with the shockwave: fast,
//           low, slowed hard by the air, lifting a little as it settles.
// They cool along `ramp` (white-hot to gold to a dim amber) and wink out.
render_mode disable_velocity, disable_force;

uniform int mode = 0;
uniform float radius = 0.5;      // skid: metres from the feet they are born within
uniform float speed_min = 1.0;   // skid: metres per second out
uniform float speed_max = 2.6;
uniform float size_min = 0.010;
uniform float size_max = 0.028;
uniform float stretch = 0.05;
uniform float energy = 1.0;
uniform sampler2D ramp : repeat_disable, filter_linear;
// the comets' helix (LevelUpFX keeps these equal to level_up_helix's)
uniform float age = 0.0;
uniform float launch = 0.08;
uniform float stagger = 0.06;
uniform float climb = 1.25;
uniform float tail = 0.5;
uniform float turns = 1.6;
uniform float top = 2.35;
uniform float foot_radius = 0.78;
uniform float crown_radius = 0.22;

uint step_rng(inout uint s) {
	s = s * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}

float rand(inout uint s) {
	return float(step_rng(s)) / 4294967295.0;
}

vec3 helix(float u, float strand) {
	float a = strand * 2.0943951 + u * turns * 6.2831853 + age * 0.6;
	float r = mix(foot_radius, crown_radius, smoothstep(0.0, 1.0, u));
	return vec3(cos(a) * r, u * top + 0.04, sin(a) * r);
}

void start() {
	uint s = NUMBER * 9781u + RANDOM_SEED * 6271u + 17u;
	step_rng(s);
	CUSTOM.x = rand(s);
	CUSTOM.y = 0.0;
	CUSTOM.z = mix(size_min, size_max, pow(rand(s), 2.0));
	CUSTOM.w = mix(0.5, 1.0, rand(s));
	TRANSFORM = mat4(1.0);
	if (mode == 0) {
		float strand = float(int(NUMBER) % 3);
		float t = (age - launch - strand * stagger) / climb;
		float head = (1.0 + tail) * (1.0 - pow(1.0 - clamp(t, 0.0, 1.0), 1.7));
		// only while the comet is on its way up
		if (t <= 0.0 || head > 1.0) {
			ACTIVE = false;
		}
		float u = clamp(head - rand(s) * 0.06, 0.0, 1.0);
		vec3 here = helix(u, strand);
		vec3 along = normalize(helix(u + 0.01, strand) - here);
		vec3 jitter = vec3(rand(s) - 0.5, rand(s) - 0.5, rand(s) - 0.5) * 0.09;
		TRANSFORM[3].xyz = here + jitter;
		// carried a little along the comet's path, loosened outward
		vec3 out_dir = normalize(vec3(here.x, 0.0, here.z) + vec3(0.0001));
		VELOCITY = along * mix(0.6, 1.6, rand(s)) + out_dir * mix(0.1, 0.5, rand(s))
			+ vec3(0.0, mix(0.1, 0.5, rand(s)), 0.0);
	} else {
		float a = rand(s) * 6.2831853;
		float speed = mix(speed_min, speed_max, pow(rand(s), 0.7));
		VELOCITY = vec3(cos(a) * speed, mix(0.15, 0.8, rand(s)), sin(a) * speed);
		TRANSFORM[3].xyz = EMISSION_TRANSFORM[3].xyz + vec3(cos(a), 0.0, sin(a)) * radius * rand(s)
			+ vec3(0.0, 0.06, 0.0);
	}
	COLOR = texture(ramp, vec2(0.0, 0.5));
}

void process() {
	CUSTOM.y += DELTA / max(0.01, LIFETIME * CUSTOM.w);
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	}
	float life = clamp(CUSTOM.y, 0.0, 1.0);
	float seed = CUSTOM.x * 97.0;
	vec3 p = TRANSFORM[3].xyz;
	vec3 v = VELOCITY;
	if (mode == 0) {
		// the air takes the comet's pace off it; a little heat lifts it
		v /= 1.0 + 2.2 * DELTA;
		v.y += (0.45 - v.y) * 1.2 * DELTA;
		float k = TIME * 3.0;
		v += 0.8 * DELTA * vec3(sin(k + seed * 7.1 + p.y * 3.0), 0.0, cos(k * 1.1 + seed * 5.7 + p.y * 2.7));
	} else {
		v.xz /= 1.0 + 2.8 * DELTA;
		v.y += (0.35 - v.y) * 1.8 * DELTA;
	}
	p += v * DELTA;
	VELOCITY = v;
	float r_size = CUSTOM.z * (1.0 - life * life * 0.5);
	float speed = length(v);
	vec3 y = speed > 0.001 ? v / speed : vec3(0.0, 1.0, 0.0);
	vec3 x = normalize(abs(y.y) < 0.99 ? cross(y, vec3(0.0, 1.0, 0.0)) : vec3(1.0, 0.0, 0.0));
	vec3 z = cross(x, y);
	TRANSFORM[0] = vec4(x * r_size, 0.0);
	TRANSFORM[1] = vec4(y * max(r_size, speed * stretch), 0.0);
	TRANSFORM[2] = vec4(z * r_size, 0.0);
	TRANSFORM[3] = vec4(p, 1.0);
	vec4 c = texture(ramp, vec2(life, 0.5));
	float twinkle = 0.65 + 0.35 * sin(TIME * 23.0 + seed * 13.0);
	COLOR = vec4(c.rgb * energy * twinkle, c.a);
}
