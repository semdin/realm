shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

// The inside of the loot chest (its model's "ChestInside" faces: the rim, the
// cavity and the lid's hollow, tools/art/split_chest.py): dark planks whose
// grain comes from the erosion noise stretched along the boards, and, once
// the lid is up (ChestView sets `inside_glow`), the light of what lies inside
// welling up from the floor in the chest's own colour and breathing on the
// grain. The UVs are the split script's planar ones (2 per metre).
// Fixed slots, clear of chest_rim's (0-7) on the same meshes.
instance uniform vec4 inside_tint : source_color, instance_index(14) = vec4(1.0, 0.78, 0.36, 1.0);
instance uniform float inside_glow : instance_index(15) = 0.0;
uniform sampler2D noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 wood : source_color = vec3(0.1, 0.055, 0.03);
// The model's heights (Blender metres, mesh space): the cavity floor and the rim.
uniform float floor_y = 0.07;
uniform float rim_y = 0.238;

varying float local_y;

void vertex() {
	local_y = VERTEX.y;
}

void fragment() {
	// boards: the grain runs along u; seams every 1/8 of v
	vec2 uv = UV;
	float grain = texture(noise, vec2(uv.x * 0.35, uv.y * 5.0)).r;
	float fine = texture(noise, vec2(uv.x * 1.7 + 0.31, uv.y * 19.0)).r;
	// each board its own tone (no drawn seams: the tone steps make them)
	float board = floor(uv.y * 8.0);
	float tone = texture(noise, vec2(board * 0.137 + 0.05, 0.43)).r;
	float wood_light = (0.55 + 0.6 * grain) * (0.85 + 0.3 * fine) * (0.7 + 0.5 * tone);
	ALBEDO = wood * wood_light;
	ROUGHNESS = 0.82;
	SPECULAR = 0.3;
	// the glow from below: the floor brightest, the rim faint (the lid's
	// hollow, low in its own space, reads as lit; ChestView gives it less)
	float depth = smoothstep(rim_y, floor_y, local_y);
	float breathe = 0.85 + 0.15 * sin(TIME * 2.2 + grain * 6.0);
	EMISSION = inside_tint.rgb * inside_glow * (0.03 + 0.97 * depth * depth * depth) * breathe * (0.45 + 0.8 * grain) * 0.7;
}

// An inside is in its own shade: lights reach it at a fraction (the chest's
// own light hangs a hand over the rim and would burn the boards white), no
// glints; the glow from the floor does the work.
void light() {
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI * 0.28;
}
