shader_type canvas_item;
render_mode unshaded;

// The screen's edge when health runs low: blood-dark smoke creeping in from
// every border, its inner edge eaten ragged by the spell effects' cloud map
// (two layers drifting inward against each other) with a hot rim of embers
// where it burns, beating with a heart. No drawn shapes and no flat fill:
// the old client's flat red sheet over the whole screen read as a tint, not
// as being hurt. `strength` 0..1 is how low the health is.

uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform float strength : hint_range(0.0, 1.0) = 0.0;
uniform float aspect = 1.7778;

void fragment() {
	// How far in from the nearest border (0 at the edge, 0.5 at the centre),
	// rounded into the corners so they fill first.
	// (in screen heights, so the sides and the top reach in alike)
	vec2 q = min(UV, 1.0 - UV) * vec2(aspect, 1.0);
	float border = min(q.x, q.y);
	float corner = length(max(vec2(0.18) - q, 0.0));
	float e = border - corner * 0.8;
	float t = TIME;
	// A heartbeat: two quick swells, then rest; faster when lower.
	float beat = fract(t * (1.0 + 0.6 * strength));
	float pulse = exp(-pow((beat - 0.08) * 14.0, 2.0)) + 0.6 * exp(-pow((beat - 0.28) * 14.0, 2.0));
	// Cloud map in screen space, drifting toward the centre.
	vec2 p = (UV - 0.5) * vec2(aspect, 1.0);
	vec2 dir = normalize(p + 1e-4);
	float n1 = texture(noise, p * 0.55 - dir * t * 0.04 + vec2(t * 0.008, 0.0)).r;
	float n2 = texture(noise, p * 1.4 + dir * t * 0.025 + vec2(0.0, t * 0.015)).r;
	float flow = n1 * 0.6 + n2 * 0.4;
	// How far in the smoke reaches, wavering with the flow and the beat.
	float reach = mix(0.03, 0.18, strength) * (0.7 + 0.6 * flow) + 0.015 * pulse * strength;
	float inside = reach - e;                  // > 0: in the smoke
	float smoke = smoothstep(-0.02, 0.12, inside);
	// The burning rim where the smoke eats inward.
	float rim = exp(-pow(inside / 0.012, 2.0)) * smoothstep(0.5, 0.8, flow);
	vec3 deep = vec3(0.14, 0.0, 0.01);
	vec3 blood = vec3(0.5, 0.02, 0.03);
	vec3 ember = vec3(1.0, 0.38, 0.12);
	vec3 col = mix(blood, deep, smoothstep(0.0, 0.2, inside));
	col = mix(col, ember, clamp(rim * (0.5 + 0.7 * pulse), 0.0, 1.0));
	float a = (smoke * (0.5 + 0.3 * smoothstep(0.0, 0.2, inside)) + rim * 0.45) * (0.55 + 0.45 * strength)
		* (0.85 + 0.2 * pulse);
	COLOR = vec4(col, clamp(a, 0.0, 0.7));
}
