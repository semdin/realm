shader_type spatial;
// The far mountains on the low preset: one rock projection and no fine bump
// (horizon_mountains.gdshaderinc). Six texture reads instead of eleven.
#define LITE
#include "res://assets/shaders/horizon_mountains.gdshaderinc"
