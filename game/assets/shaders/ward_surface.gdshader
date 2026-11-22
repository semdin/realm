shader_type spatial;
// Ward Shield's shell, its near side (see ward_surface.gdshaderinc).
render_mode unshaded, blend_premul_alpha, cull_back, depth_draw_never, shadows_disabled, fog_disabled;

#define SIDE_STRENGTH 1.0
#include "res://assets/shaders/ward_surface.gdshaderinc"
