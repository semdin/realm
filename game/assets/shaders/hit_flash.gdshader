shader_type spatial;
// A creature struck by a blow: a hot rim of light over its own surface for a
// few frames (CreatureView.flinch), brightest at the silhouette and a little
// over the face turned to the camera, fading with `hit_flash`. Worn as the
// mesh's material_overlay only while it fades.
render_mode blend_add, unshaded, cull_back, depth_draw_never, fog_disabled, shadows_disabled;

instance uniform float hit_flash : hint_range(0.0, 1.0) = 0.0;
uniform vec3 tint : source_color = vec3(1.0, 0.96, 0.88);

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, 2.2);
	ALBEDO = tint * (0.05 + rim * 1.1) * hit_flash;
}
