shader_type spatial;
// The waypoint's beacon (scripts/world/way_finder.gd): a tall soft column of
// gold light over the goal, brightest at its foot and fading out above,
// its body the erosion cloud (the spells' noise map) streaming upward so it
// smoulders rather than standing as a tube; the embers rising through it
// are RisingMotes. The column is lit by how squarely each pixel faces the
// eye, so it has no edge and no seam from any side. With `ember` it is one
// of the flight route's drifting embers instead: a soft glowing mote, the
// same cloud breaking its edge.
render_mode unshaded, blend_add, cull_back, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 tint : source_color = vec4(1.0, 0.76, 0.34, 1.0);
uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform bool ember = false;
uniform float strength = 0.75;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (ember) {
		// each ember faces the camera
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	}
}

void fragment() {
	if (ember) {
		vec2 p = UV - vec2(0.5);
		float cloud = texture(noise, UV * 0.7 + vec2(TIME * 0.21, TIME * 0.13)).r;
		float core = 1.0 - smoothstep(0.0, 0.5, length(p) * (0.75 + 0.6 * cloud));
		ALBEDO = tint.rgb * core * core * 2.2 * strength;
	} else {
		// metres above the foot (the column is 140 m tall, centred 70 up)
		float up = clamp(1.0 - UV.y, 0.0, 1.0) * 140.0;
		float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
		float core = pow(facing, 2.5);
		float cloud = texture(noise, vec2(UV.x * 3.0, up * 0.035 - TIME * 0.22)).r;
		float wisps = texture(noise, vec2(UV.x * 7.0 + 0.37, up * 0.09 - TIME * 0.55)).r;
		float body = smoothstep(0.2, 0.9, cloud * 0.75 + wisps * 0.45);
		// bright at the foot, gone by ~60 m
		float fall = exp(-up * 0.045) + 0.6 * exp(-up * 0.6);
		ALBEDO = tint.rgb * core * (0.2 + 0.8 * body) * fall * strength;
	}
}
