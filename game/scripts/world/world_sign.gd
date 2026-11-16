extends Label3D

## (No class_name: callers preload this script, so a headless run needs no
## re-import for it.)

## A label standing in the world (a building's name over its door, a landing
## pad, a Waylink, a chest): its own world size near by; farther out it grows
## just enough that its letters never drop below `min_em_px` on screen (world
## labels used to shrink to 1-2 px specks), and from `reach` metres of where
## it was placed it fades out over FADE metres instead of hanging on as a
## smudge. A second line belongs under it as a child (`fade_line`), so it
## grows and fades with it.
##
## Grown, a sign is wider than the front it was placed before, and its own
## building would cut through it: it steps toward the camera along the line
## of sight by the width it gained (the same spot on screen), so only what
## stands well between hides it.
##
## The fade is the sign's own, measured from its place (its letters' and
## outline's alpha, set only while it changes; past the fade it leaves every
## render layer, so it is not drawn at all and a caller's `visible` stays the
## caller's). The engine's visibility range
## measured from where the grown sign stood and how far its grown box
## reached, so a far sign came up to 40 % nearer and never faded (Kestrin's
## Forge read across the valley).
##
## What it shows depends on the camera's distance alone: a quest naming the
## place changes nothing.

## The smallest font height on screen, pixels at the window's height.
const MIN_EM_PX := 17.0
## The fade's length past `reach` (metres).
const FADE := 14.0

var min_em_px := MIN_EM_PX
## Metres from its place where it starts to fade (0: never).
var reach := 0.0
## How much of it shows now (1 whole, 0 gone; the check reads it).
var shown := 1.0
## Where the sign was placed (its parent's space), read on the first frame,
## the labels that fade (itself and the lines under it) with their own
## alphas [label, letters, outline], and the render layers it is drawn on.
var _home := Vector3.INF
var _faders: Array = []
var _layers := 1

func _init() -> void:
	# after main.gd and the checks have placed this frame's camera
	process_priority = 1000

## Fade out past `reach_m` metres (and keep `em_px` letters until then).
func setup(reach_m: float, em_px := MIN_EM_PX) -> Label3D:
	reach = reach_m
	min_em_px = em_px
	return self

## A line that hangs under a sign (a child, scaled with it): it fades with the
## sign (the sign finds it among its children; `reach` is the sign's).
static func fade_line(line: Label3D, _reach_m: float) -> void:
	line.set_meta(&"sign_line", true)

func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or not visible:
		return
	if _home == Vector3.INF:
		_home = position
		_layers = layers
		for label: Node in [self as Node] + get_children():
			if label is Label3D:
				_faders.append([label, (label as Label3D).modulate.a, (label as Label3D).outline_modulate.a])
	var parent := get_parent() as Node3D
	var home := parent.global_transform * _home if parent != null else _home
	var to_cam := cam.global_position - home
	var d := maxf(to_cam.length(), 0.01)
	var show := 1.0 if reach <= 0.0 else clampf((reach + FADE - d) / FADE, 0.0, 1.0)
	_fade(show)
	if show <= 0.0:
		return
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

## Show `amount` of the sign and its lines (set only when it changed).
func _fade(amount: float) -> void:
	if absf(amount - shown) < 0.02 and (amount > 0.0) == (shown > 0.0) and (amount < 1.0) == (shown < 1.0):
		return
	shown = amount
	for entry: Array in _faders:
		var label: Label3D = entry[0]
		label.modulate.a = float(entry[1]) * amount
		label.outline_modulate.a = float(entry[2]) * amount
		label.layers = 0 if amount <= 0.0 else _layers
