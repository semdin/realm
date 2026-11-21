// The login screen's world, in one pass over the whole window: the key art
// cover-fitted with a slow push-in and a little pointer parallax, the
// aurora breathing, the light at the mage's wand tip (halo, slow rays, a
// flickering core), the shade behind the login column, the bottom fade and
// the vignette, faded in from black (`intro`).
shader_type canvas_item;

uniform sampler2D art : source_color, filter_linear, repeat_disable;
uniform vec2 art_size = vec2(2560.0, 1440.0);
// The rect's size in canvas units (set on resize).
uniform vec2 view_size = vec2(1600.0, 900.0);
// The pointer from the centre (-0.5..0.5), smoothed by the script.
uniform vec2 parallax = vec2(0.0);
// Where the wand's tip is in the painting (pixels).
uniform vec2 wand_at = vec2(2175.0, 620.0);
uniform float intro : hint_range(0.0, 1.0) = 1.0;
// How far the login column's shade reaches (canvas units).
uniform float column_px = 560.0;

float bump(vec2 p, vec2 c, vec2 r) {
	return 1.0 - smoothstep(0.0, 1.0, length((p - c) / r));
}

void fragment() {
	vec2 uv = UV;
	// cover: the share of the painting the window shows
	float s = max(view_size.x / art_size.x, view_size.y / art_size.y);
	vec2 shown = view_size / (art_size * s);
	// a slow push-in toward the castle and back (38 s each way), never
	// showing an edge, and the pointer's parallax
	float t = 0.5 - 0.5 * cos(TIME * 6.2831853 / 76.0);
	float zoom = 1.03 + 0.06 * t;
	vec2 focus = vec2(0.70, 0.45);
	vec2 img = (uv - 0.5) * shown + 0.5;
	img = focus + (img - focus) / zoom;
	img -= parallax * vec2(0.009, 0.007) * shown;
	vec3 col = texture(art, img).rgb;

	// the aurora breathes (screen-blended glow over its ribbons)
	float breathe = mix(0.10, 0.32, 0.5 + 0.5 * sin(TIME * 6.2831853 / 7.0));
	vec3 aurora = vec3(0.31, 0.90, 0.75) * 0.55 * bump(img, vec2(0.72, 0.22), vec2(0.18, 0.30))
		+ vec3(1.0, 0.84, 0.47) * 0.45 * bump(img, vec2(0.74, 0.28), vec2(0.10, 0.22));
	col = 1.0 - (1.0 - col) * (1.0 - clamp(aurora * breathe, 0.0, 1.0));

	// the wand's light, measured in the painting's pixels
	vec2 p = img * art_size - wand_at;
	float d = length(p);
	float pulse = 0.82 + 0.18 * sin(TIME * 6.2831853 / 3.2);
	float flick = 0.9 + 0.1 * step(0.5, fract(sin(floor(TIME * 11.0) * 91.7) * 4375.85));
	float halo = 0.5 * exp(-pow(d / (95.0 * (0.92 + 0.16 * pulse)), 1.5)) * pulse;
	float core = exp(-pow(d / 13.0, 2.0)) * flick;
	float ang = atan(p.y, p.x) + TIME * 0.157;
	float rays = pow(max(cos(ang * 15.0), 0.0), 24.0) * exp(-d / 70.0) * smoothstep(4.0, 22.0, d) * 0.5;
	vec3 wand = vec3(0.62, 0.78, 1.0) * halo + vec3(0.85, 0.92, 1.0) * rays + vec3(1.0) * core;
	col = 1.0 - (1.0 - col) * (1.0 - clamp(wand, 0.0, 1.0));

	// the shade behind the login column (in canvas units, so it follows the
	// column at any window width), the bottom fade, the vignette
	float x = uv.x * view_size.x;
	float k = column_px / 560.0;
	float shade = 0.93;
	shade = mix(shade, 0.80, smoothstep(0.0, 500.0 * k, x));
	shade = mix(shade, 0.38, smoothstep(500.0 * k, 845.0 * k, x));
	shade = mix(shade, 0.0, smoothstep(845.0 * k, 1150.0 * k, x));
	col = mix(col, vec3(0.012, 0.02, 0.04), shade);
	col *= 1.0 - 0.72 * smoothstep(0.72, 1.0, uv.y);
	float vig = smoothstep(0.55, 1.0, length((uv - vec2(0.6, 0.45)) / vec2(1.3, 1.0)));
	col *= 1.0 - 0.55 * vig;
	COLOR = vec4(col * intro, 1.0);
}
