extends Control
class_name MapMarker

## The player's marker on the maps (the old game's): the painted gold arrow
## that turns with the way the character faces, over a soft light cone for
## where the camera looks. Map space is world x to the right and world z
## downwards, so a world direction (dx, dz) is drawn as Vector2(dx, dz).

var facing := Vector2(0, -1)
var camera_dir := Vector2(0, -1)
var cone_length := 70.0

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	var c := size * 0.5
	draw_view_cone(self, c, camera_dir, cone_length)
	draw_arrow(self, c, facing, 11.0)

## A translucent wedge (about 70 degrees) fading out from `at` along `dir`.
static func draw_view_cone(canvas: CanvasItem, at: Vector2, dir: Vector2, length: float) -> void:
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	var half := deg_to_rad(35.0)
	var rings := 6
	for i in range(rings, 0, -1):
		var r := length * float(i) / rings
		var a := 0.30 * (1.0 - float(i - 1) / rings)
		var pts := PackedVector2Array([at])
		var steps := 14
		for s in range(steps + 1):
			var ang := -half + 2.0 * half * float(s) / steps
			pts.append(at + dir.rotated(ang) * r)
		canvas.draw_colored_polygon(pts, Color(1.0, 0.93, 0.62, a * 0.55))

## The painted gold arrowhead from the icon set, turned to face `dir` (it is
## authored pointing up).
static func draw_arrow(canvas: CanvasItem, at: Vector2, dir: Vector2, radius: float) -> void:
	if dir.length_squared() < 0.0001:
		dir = Vector2(0, -1)
	dir = dir.normalized()
	var art := UITheme.chrome("minimap_player")
	var s := radius * 2.6
	canvas.draw_set_transform(at, dir.angle() + PI * 0.5, Vector2.ONE)
	if art != null:
		canvas.draw_texture_rect(art, Rect2(Vector2(-s, -s) * 0.5, Vector2(s, s)), false)
	else:
		canvas.draw_colored_polygon(PackedVector2Array([Vector2(0, -radius), Vector2(radius * 0.75, radius * 0.7),
			Vector2(0, radius * 0.25), Vector2(-radius * 0.75, radius * 0.7)]), HudKit.GOLD_LT)
	canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
