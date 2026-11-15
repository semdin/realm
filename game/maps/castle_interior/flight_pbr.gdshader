shader_type spatial;
// The castle's triplanar PBR surface (assets/shaders/triplanar_pbr.gdshader,
// lite path) sampled in the mesh's own space instead of the world's: a moving
// staircase flight keeps its stone and planks on itself while it swings
// (world-space sampling would slide the texture across the moving deck).
// The flight's meshes are built unscaled in the flight's own frame, so one
// tile still spans 1 / world_scale metres.
// A flight hangs in the open stairwell, seen from below by everyone on the
// floors under it, where no lamp reaches its underside: `bounce` is the warm
// light the floors and galleries throw up at it (full on faces turned down,
// half on the risers and sides), so it reads as stone instead of a black
// wedge and the steps do not stripe black.

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float world_scale = 0.125;
uniform float normal_strength : hint_range(0.0, 3.0) = 1.0;
uniform bool lite = true;
uniform float lite_roughness : hint_range(0.0, 1.0) = 0.82;
uniform vec3 bounce_colour : source_color = vec3(1.0, 0.82, 0.62);
uniform float bounce = 0.22;

varying vec3 local_pos;
varying vec3 local_nrm;

void vertex() {
	local_pos = VERTEX;
	local_nrm = NORMAL;
}

void fragment() {
	vec3 n = normalize(local_nrm);
	vec3 an = abs(n);
	vec2 uv;
	vec3 t;
	vec3 b;
	if (an.y >= an.x && an.y >= an.z) {
		uv = local_pos.xz * world_scale;
		t = vec3(1.0, 0.0, 0.0);
		b = vec3(0.0, 0.0, 1.0);
	} else if (an.x >= an.z) {
		uv = local_pos.zy * world_scale;
		t = vec3(0.0, 0.0, 1.0);
		b = vec3(0.0, 1.0, 0.0);
	} else {
		uv = local_pos.xy * world_scale;
		t = vec3(1.0, 0.0, 0.0);
		b = vec3(0.0, 1.0, 0.0);
	}
	vec3 tn;
	tn.xy = (texture(normal_tex, uv).xy * 2.0 - 1.0) * normal_strength;
	tn.z = sqrt(max(1.0 - dot(tn.xy, tn.xy), 0.0));
	float handed = sign(dot(n, cross(t, b)));
	vec3 local_normal = normalize(tn.x * t + tn.y * b * handed + tn.z * n);
	vec3 albedo = texture(albedo_tex, uv).rgb * tint;
	vec3 world_normal = normalize(MODEL_NORMAL_MATRIX * local_normal);
	ALBEDO = albedo;
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
	float facing = clamp(-world_normal.y, 0.0, 1.0) + 0.5 * (1.0 - abs(world_normal.y));
	EMISSION = albedo * bounce_colour * bounce * facing;
	ROUGHNESS = lite ? lite_roughness : texture(rough_tex, uv).r;
	AO = lite ? 1.0 : texture(ao_tex, uv).r;
	AO_LIGHT_AFFECT = 0.35;
}
