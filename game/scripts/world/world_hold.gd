extends RefCounted
class_name WorldHold

## Keeps the world from being drawn while the loading screen covers it.
##
## A draw waits on the main thread for any pipeline it needs that is not ready,
## and on a first start on Metal that wait can last minutes with the screen
## frozen. What enters the scene has its pipelines queued on the worker pool
## whether it is drawn or not, so while this holds (the camera sees no layer, no
## light casts a shadow) they compile in the background and the frames, the bar
## and the rune go on. `release` lets the camera see again.

var _main: Node
var _camera: Camera3D
var _mask := 0
var _lights: Dictionary = {}   # Light3D -> its shadow caster mask

func begin(main: Node) -> void:
	_main = main
	_camera = main.get("camera") as Camera3D
	if _camera != null:
		_mask = _camera.cull_mask
		_camera.cull_mask = 0
	cover_lights()

## The lights that came with the map hold too.
func cover_lights() -> void:
	if _main == null:
		return
	for node: Node in _main.find_children("*", "Light3D", true, false):
		var light := node as Light3D
		if light.shadow_enabled and not _lights.has(light):
			_lights[light] = light.shadow_caster_mask
			light.shadow_caster_mask = 0

func release() -> void:
	if _main == null:
		return
	_main = null
	if is_instance_valid(_camera):
		_camera.cull_mask = _mask
	for light: Variant in _lights:
		if is_instance_valid(light):
			(light as Light3D).shadow_caster_mask = int(_lights[light])
	_lights.clear()
