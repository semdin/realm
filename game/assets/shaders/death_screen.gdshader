shader_type canvas_item;

// The death screen's world (death_screen.gd): the frame behind drained of
// colour and darkened, a vignette closing in from the edges and a blood-dark
// rise from below; `amount` brings it in over the first second.
uniform sampler2D screen : hint_screen_texture, filter_linear;
uniform float amount = 0.0;

void fragment() {
	vec3 c = texture(screen, SCREEN_UV).rgb;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	vec3 drained = mix(c, vec3(l), 0.88) * 0.52;
	vec2 d = SCREEN_UV - vec2(0.5, 0.52);
	d.x *= SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	float v = smoothstep(0.32, 0.85, length(d * vec2(1.0, 1.2)));
	drained *= 1.0 - v * 0.8;
	drained += vec3(0.32, 0.02, 0.04) * smoothstep(0.62, 1.12, SCREEN_UV.y) * 0.55;
	COLOR = vec4(mix(c, drained, amount), 1.0);
}
