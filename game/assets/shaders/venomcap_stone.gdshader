// The Venomcap Stone's body (assets/models/monolith/venomcap_stone.tscn): the
// caverns' glowing mushrooms (cavern_mushrooms.glb's baked maps) grown into a
// grove, their teal caps turned to venom green and lit from within. The glow
// is painted (the low preset draws no glow pass): the caps' own texture
// carries it, brightest in their pale spots, breathing in slow swells that
// climb the cluster. Stems and moss stay as they are.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D mr_tex : hint_default_white, filter_linear_mipmap;
// the stone's glow (creature_views.json `glow`)
uniform vec4 glow : source_color = vec4(0.6, 1.0, 0.3, 1.0);
uniform float energy = 0.55;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	vec3 a = texture(albedo_tex, UV).rgb;
	// the caps: the cavern teal (green and blue over red)
	float cap = clamp((min(a.g, a.b) - a.r) * 4.0 - 0.15, 0.0, 1.0);
	float lum = dot(a, vec3(0.3, 0.59, 0.11));
	vec3 venom = glow.rgb * (0.25 + lum * 1.1);
	ALBEDO = mix(a, venom, cap * 0.85);
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	vec4 mr = texture(mr_tex, UV);
	ROUGHNESS = mr.g;
	METALLIC = mr.b * 0.3;
	float swell = 0.5 + 0.5 * sin(TIME * 1.6 - local_pos.y * 2.0 + sin(local_pos.x * 2.3 + local_pos.z * 1.7) * 1.5);
	EMISSION = glow.rgb * cap * (0.35 + 0.65 * swell) * (0.35 + lum) * energy;
}
