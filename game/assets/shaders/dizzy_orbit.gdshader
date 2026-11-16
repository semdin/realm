shader_type particles;
// A stunned body's dizziness (StatusFX): a few small comets of light chasing
// each other round a thin, wobbling ring over the head, each a bright mote
// with a tail of fainter ones curving behind it along the ring, and a little
// dust of motes drifting round with them that twinkle in and out. Every
// particle's place is a function of the time (nothing integrates, nothing
// drifts off), drawn by ember_spark.gdshader like every spark in the game
// (the basis carries the size; the Y axis the tail segment along the ring).
// Local coordinates: the emitter sits at the ring's centre over the head.
render_mode disable_velocity, disable_force;

uniform float radius = 0.3;
// the ring's lean and how fast that lean swings round (the wobble)
uniform float tilt = 0.32;
uniform float wobble = 1.3;
uniform float speed = 3.6;          // radians a second
uniform int comets = 3;
uniform int tail = 8;               // particles per comet, its head first
uniform float tail_gap = 0.09;      // radians between a comet's particles
uniform float size_head = 0.016;
uniform float size_dust = 0.006;
uniform float energy = 1.0;
uniform float strength = 1.0;       // StatusFX fades it in and out
uniform sampler2D ramp : repeat_disable, filter_linear;

float hash(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

void start() {
	TRANSFORM = mat4(1.0);
	VELOCITY = vec3(0.0);
	COLOR = vec4(0.0);
}

void process() {
	float t = TIME;
	int i = int(INDEX);
	int in_comets = comets * tail;
	// the ring's lean swings round: its normal circles the vertical
	vec3 n = normalize(vec3(sin(tilt) * cos(t * wobble), cos(tilt), sin(tilt) * sin(t * wobble)));
	vec3 u = normalize(cross(n, vec3(0.0, 0.0, 1.0)));
	vec3 w = cross(n, u);
	float phase;
	float r = radius;
	float size;
	float glow;
	float along;
	float lift = 0.0;
	if (i < in_comets) {
		int k = i / tail;
		int j = i - k * tail;
		float f = float(j) / float(tail);
		phase = t * speed + float(k) * 6.2831853 / float(comets) - float(j) * tail_gap;
		r *= 1.0 + 0.07 * sin(phase * 2.0 + float(k) * 1.7);
		size = size_head * mix(1.0, 0.3, f);
		glow = pow(1.0 - f, 1.6) * (0.8 + 0.2 * sin(t * 11.0 + float(k) * 2.3));
		along = r * tail_gap * 1.15;
		lift = 0.025 * sin(t * 2.6 + float(k) * 2.0);
	} else {
		float s = float(i - in_comets) + 1.0;
		phase = t * speed * mix(0.55, 0.9, hash(s)) + hash(s * 3.1) * 6.2831853;
		r *= mix(0.72, 1.3, hash(s * 5.7));
		size = size_dust * mix(0.7, 1.4, hash(s * 7.3));
		// each mote breathes in and out on its own beat
		float beat = sin(t * mix(2.0, 4.5, hash(s * 9.1)) + hash(s * 2.9) * 6.2831853);
		glow = pow(max(0.0, beat), 3.0) * 0.8;
		along = size;
		lift = (hash(s * 4.3) - 0.5) * 0.12 + 0.03 * sin(t * 1.7 + s);
	}
	vec3 radial = u * cos(phase) + w * sin(phase);
	vec3 tangent = -u * sin(phase) + w * cos(phase);
	vec3 p = radial * r + n * lift;
	vec3 x = normalize(cross(tangent, n));
	TRANSFORM[0] = vec4(x * size, 0.0);
	TRANSFORM[1] = vec4(tangent * max(size, along), 0.0);
	TRANSFORM[2] = vec4(n * size, 0.0);
	TRANSFORM[3] = vec4(p, 1.0);
	vec4 c = texture(ramp, vec2(i < in_comets ? float(i - (i / tail) * tail) / float(tail) : 0.55, 0.5));
	COLOR = vec4(c.rgb * energy, c.a * clamp(glow, 0.0, 1.0) * strength);
}
