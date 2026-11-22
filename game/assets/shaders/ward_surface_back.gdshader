shader_type spatial;
// Ward Shield's shell, its far side at half strength, drawn before the near
// side (see ward_surface.gdshaderinc).
render_mode unshaded, blend_premul_alpha, cull_front, depth_draw_never, shadows_disabled, fog_disabled;

#define SIDE_STRENGTH 0.5
#include "res://assets/shaders/ward_surface.gdshaderinc"
