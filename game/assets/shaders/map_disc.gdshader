shader_type canvas_item;
// The minimap's disc (scripts/ui/hud_minimap.gd): a window onto the map's
// painted sheet (MapSheets) round the player, cut to a circle with a soft
// vignette so it sits inside the brass ring. The sheet is a texture, not a
// second camera: the disc costs one textured quad a frame.

uniform sampler2D sheet : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 centre_uv = vec2(0.5);   // the player on the sheet
uniform vec2 span_uv = vec2(0.1);     // the disc's width on the sheet
uniform vec4 outside : source_color = vec4(0.07, 0.065, 0.075, 1.0);

void fragment() {
	vec2 p = UV - vec2(0.5);
	float d = length(p);
	float edge = 1.0 - smoothstep(0.487, 0.500, d);
	vec2 uv = centre_uv + p * span_uv;
	vec4 c = texture(sheet, uv);
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		c = outside;
	}
	c.rgb *= mix(0.55, 1.0, smoothstep(0.50, 0.18, d));
	c.a = edge;
	COLOR = c;
}
