extends Label3D

## (No class_name: callers preload this script, so a headless run needs no
## re-import for it.)

## A label standing in the world (a building's name over its door, a landing
## pad, a Waylink, a chest): its own world size near by; farther out it grows
## just enough that its letters never drop below `min_em_px` on screen (world
## labels used to shrink to 1-2 px specks), and past `reach` metres it fades
## out by itself (the visibility range, VISIBILITY_RANGE_FADE_SELF) instead of
## hanging on as a smudge. A second line belongs under it as a child, so it
## grows with it.
##
## Grown, a sign is wider than the front it was placed before, and its own
## building would cut through it: it steps toward the camera along the line
## of sight by the width it gained (the same spot on screen), so only what
## stands well between hides it.

## The smallest font height on screen, pixels at the window's height.
const MIN_EM_PX := 17.0
## The fade's length past `reach` (metres).
const FADE := 14.0

var min_em_px := MIN_EM_PX
## Where the sign was placed (its parent's space), read on the first frame.
var _home := Vector3.INF

func _init() -> void:
	# after main.gd and the checks have placed this frame's camera
	process_priority = 1000

## Fade out past `reach` metres (and keep `em_px` letters until then).
func setup(reach: float, em_px := MIN_EM_PX) -> Label3D:
	min_em_px = em_px
	visibility_range_end = reach
	visibility_range_end_margin = FADE
	visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return self

## The same fade for a line that hangs under a sign (a child, scaled with it).
static func fade_line(line: Label3D, reach: float) -> void:
	line.visibility_range_end = reach
	line.visibility_range_end_margin = FADE
	line.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or not visible:
		return
	if _home == Vector3.INF:
		_home = position
	var parent := get_parent() as Node3D
	var home := parent.global_transform * _home if parent != null else _home
	var to_cam := cam.global_position - home
	var d := maxf(to_cam.length(), 0.01)
	# screen pixels per metre at this distance
	var ppm := get_viewport().get_visible_rect().size.y / (2.0 * d * tan(deg_to_rad(cam.fov) * 0.5))
	var k := maxf(1.0, min_em_px / maxf(float(font_size) * pixel_size * ppm, 0.001))
	var push := 0.0
	if k > 1.0:
		# out of its own building's way by what it grew (its added width: a
		# building seen end-on is deeper than its front is wide), then sized
		# for the nearer spot
		push = minf((k - 1.0) * get_aabb().size.x, d * 0.4)
		k = maxf(1.0, k * (d - push) / d)
	if absf(k - scale.x) > 0.01 * k:
		scale = Vector3(k, k, k)
	var at := home + to_cam / d * push
	if global_position.distance_squared_to(at) > 0.0004:
		global_position = at
