shader_type particles;
// Process shader of the broom wake (scripts/fx/broom_wake.gd). Particles live
// in world space: each one is shed at the bristle tip and stays in the air the
// broom left, so the wake streams out along the flight path, lags behind a
// turn and fades where it was left. Everything that depends on the flight is
// read at birth and kept by the particle (an older stretch of the wake does
// not change when the rider slows down):
//   * born spread back along the tip's motion this frame (`emit_motion`), so
//     a fast broom leaves a continuous wake rather than a dotted one;
//   * `rate` thins the births (a hover only breathes a few puffs out);
//   * a little of the broom's own velocity (`carry`), then drag lets it hang;
//   * `curl` (rad/s, signed): its drift turns round the vertical while it is
//     young, so a banked turn leaves a hooked swirl behind it;
//   * `burst` > 0 flings it out round the travel axis (a take-off or a hard
//     push off from a hover);
//   * a mist wisp is stretched along the travel direction (`stretch` x its
//     width) and relaxes into a round puff as it ages and grows.
// `spark` particles are the wake's glints instead: the basis carries the
// spark's radius (X) and velocity streak (Y) the way ember_spark.gdshader
// reads it, and COLOR comes from `ramp`.
// The mist's draw pass (broom_wake_puff.gdshader) reads COLOR as data:
// r = birth stretch, g = birth width, b = birth opacity, a = opacity now;
// CUSTOM: x = seed, y = age 0..1, z = life share, w = curl.
render_mode disable_velocity, disable_force;

uniform float rate = 1.0;
uniform vec3 emit_motion = vec3(0.0);
uniform vec3 carry = vec3(0.0);
uniform vec3 travel = vec3(0.0, 0.0, 1.0);
uniform float jitter = 0.4;
uniform float lift = 0.0;
uniform float drag = 2.0;
uniform float swirl = 0.6;
uniform float curl = 0.0;
uniform float burst = 0.0;
uniform float emit_radius = 0.12;
uniform float width_min = 0.3;
uniform float width_max = 0.5;
uniform float grow = 2.4;
uniform float stretch = 1.0;
uniform float opacity = 0.3;
uniform float life_scale = 1.0;
uniform bool spark = false;
uniform float spark_stretch = 0.03;
uniform sampler2D ramp : repeat_disable, filter_linear;

uint step_rng(inout uint s) {
	s = s * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}

float rand(inout uint s) {
	return float(step_rng(s)) / 4294967295.0;
}

vec3 sphere(inout uint s) {
	float z = rand(s) * 2.0 - 1.0;
	float phi = rand(s) * 6.2831853;
	float r = sqrt(max(0.0, 1.0 - z * z));
	return vec3(r * cos(phi), z, r * sin(phi));
}

void start() {
	uint s = NUMBER * 9781u + RANDOM_SEED * 6271u + 17u;
	step_rng(s);
	CUSTOM.x = rand(s);
	CUSTOM.y = 0.0;
	CUSTOM.z = life_scale * mix(0.6, 1.0, rand(s));
	CUSTOM.w = curl * mix(0.6, 1.4, rand(s));
	vec3 axis = length(travel) > 0.001 ? normalize(travel) : vec3(0.0, 0.0, 1.0);
	vec3 off = sphere(s) * emit_radius * sqrt(rand(s));
	vec3 at = EMISSION_TRANSFORM[3].xyz + off - emit_motion * rand(s);
	vec3 radial = off - axis * dot(off, axis);
	radial = length(radial) > 0.0001 ? normalize(radial) : sphere(s);
	VELOCITY = carry + sphere(s) * jitter * rand(s) + vec3(0.0, lift, 0.0)
		+ radial * burst * mix(0.5, 1.0, rand(s));
	float w = mix(width_min, width_max, rand(s));
	float along = stretch * mix(0.8, 1.2, rand(s));
	TRANSFORM = mat4(1.0);
	TRANSFORM[1] = vec4(axis * w * along, 0.0);
	TRANSFORM[3] = vec4(at, 1.0);
	COLOR = vec4(along, w, opacity * mix(0.75, 1.0, rand(s)), 0.0);
	if (spark) {
		COLOR = texture(ramp, vec2(0.0, 0.5));
		CUSTOM.z = life_scale * mix(0.5, 1.0, rand(s));
		TRANSFORM[0] = vec4(w, 0.0, 0.0, 0.0);
	}
	if (rand(s) > rate) {
		ACTIVE = false;
	}
}

void process() {
	CUSTOM.y += DELTA / max(0.01, LIFETIME * CUSTOM.z);
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	}
	float age = clamp(CUSTOM.y, 0.0, 1.0);
	vec3 p = TRANSFORM[3].xyz;
	vec3 v = VELOCITY;
	float seed = CUSTOM.x * 97.0;
	v /= 1.0 + drag * DELTA;
	// the curl: the drift turns round the vertical while the particle is young
	// (positive turns +x toward +z, i.e. against atan2(x, z) headings)
	float turn = CUSTOM.w * DELTA * (1.0 - age);
	float c = cos(turn);
	float sn = sin(turn);
	v.xz = vec2(v.x * c - v.z * sn, v.x * sn + v.z * c);
	// a slow lift (or sink) and the air's own stirring
	v.y += lift * 0.6 * DELTA;
	float k = TIME * 1.7;
	v += swirl * DELTA * vec3(
		sin(k * 1.3 + seed * 7.1 + p.y * 1.9 + p.z * 0.7),
		sin(k * 1.1 + seed * 3.3 + p.x * 1.3) * 0.5,
		cos(k * 0.9 + seed * 5.7 + p.x * 0.8 + p.y * 1.7));
	p += v * DELTA;
	VELOCITY = v;
	if (spark) {
		// the birth radius rides in X's length from frame to frame
		float r = length(TRANSFORM[0].xyz);
		float speed = length(v);
		vec3 y = speed > 0.001 ? v / speed : vec3(0.0, 1.0, 0.0);
		vec3 x = normalize(abs(y.y) < 0.99 ? cross(y, vec3(0.0, 1.0, 0.0)) : vec3(1.0, 0.0, 0.0));
		vec3 z = cross(x, y);
		TRANSFORM[0] = vec4(x * r, 0.0);
		TRANSFORM[1] = vec4(y * max(r, speed * spark_stretch), 0.0);
		TRANSFORM[2] = vec4(z * r, 0.0);
		TRANSFORM[3] = vec4(p, 1.0);
		vec4 tint = texture(ramp, vec2(age, 0.5));
		float twinkle = 0.7 + 0.3 * sin(TIME * 23.0 + seed * 13.0);
		COLOR = vec4(tint.rgb * twinkle, tint.a);
	} else {
		vec3 along = TRANSFORM[1].xyz;
		float along_len = length(along);
		along = along_len > 0.00001 ? along / along_len : vec3(0.0, 0.0, 1.0);
		float width = COLOR.g * mix(1.0, grow, sqrt(age));
		float length_now = width * mix(COLOR.r, 1.15, smoothstep(0.0, 0.8, age));
		vec3 x = normalize(abs(along.y) < 0.99 ? cross(along, vec3(0.0, 1.0, 0.0)) : vec3(1.0, 0.0, 0.0));
		vec3 z = cross(x, along);
		TRANSFORM[0] = vec4(x * width, 0.0);
		TRANSFORM[1] = vec4(along * length_now, 0.0);
		TRANSFORM[2] = vec4(z * width, 0.0);
		TRANSFORM[3] = vec4(p, 1.0);
		// in quickly, out slowly
		COLOR.a = COLOR.b * smoothstep(0.0, 0.01, age) * pow(1.0 - age, 1.2);
	}
}
