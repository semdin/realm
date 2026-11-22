// The web binding a cavern stone (the Venomcap and Broodclutch Stones'
// `Silk`): sheets of silk drawn over and between the heap, and a few orb webs
// strung across it, in one mesh. A sheet (COLOR.r 0) is a ribbon (UV.x
// across it, UV.y metres along it): its silk is the erosion cloud stretched
// along the ribbon into fibres, thinning to wisps at its ragged sides and
// ends, so it never shows a ruled edge. An orb web (COLOR.r 1) is the
// caverns' dew-beaded web photo (cobweb_1024). COLOR.g varies each piece's
// brightness. Lit by the cave and the stone's own light; a little of the
// stone's glow caught in it (`tint`).
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D fibres : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform sampler2D web : repeat_disable, filter_linear_mipmap_anisotropic, hint_default_black;
uniform vec3 silk : source_color = vec3(0.86, 0.86, 0.9);
uniform vec3 tint : source_color = vec3(0.6, 1.0, 0.3);
uniform float opacity = 0.8;
uniform float glint = 0.25;

void fragment() {
	float orb = COLOR.r;
	float bright = 0.75 + 0.5 * COLOR.g;
	float a;
	if (orb > 0.5) {
		a = clamp(texture(web, UV).r * 1.5, 0.0, 1.0);
	} else {
		// fibres: the cloud drawn out along the sheet
		float f1 = texture(fibres, vec2(UV.x * 0.55 + COLOR.g * 3.0, UV.y * 0.05)).r;
		float f2 = texture(fibres, vec2(UV.x * 1.4 + 0.37, UV.y * 0.11 + COLOR.g)).r;
		float across = abs(UV.x - 0.5) * 2.0;
		// ragged sides: the cloud eats the sheet toward its edges
		float body = 1.0 - smoothstep(0.25 + 0.45 * f1, 1.0, across);
		a = body * smoothstep(0.25, 0.75, f1 * 0.55 + f2 * 0.6) * 0.85;
		// its ends taper off (COLOR.b: 0 at an end, 1 in the middle)
		a *= smoothstep(0.0, 0.6, COLOR.b);
	}
	ALBEDO = silk * bright;
	ROUGHNESS = 0.6;
	SPECULAR = 0.4;
	EMISSION = tint * glint * a;
	ALPHA = clamp(a * opacity, 0.0, 1.0);
}
