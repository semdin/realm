extends Node3D
class_name BroomRig

## The windskiff a hero rides (the `broom` equipment slot keeps its old id):
## the equipped item's model (items.json `model`, built by
## tools/art/skiff_art.py; every skiff carries the same nodes) and the sockets
## the pose layers read:
##   SeatSocket         where the rider's hips sit (HeroView puts it under them)
##   HandL/RSocket      the two ends of the helm bar (BroomGripModifier)
##   FootL/RSocket      the ankles, on the floor of the well (BroomGripModifier)
##   GripSocket         the fore end of the line the cloak lies along
##   TailSocket         the stern (that line's aft end, and the wake)
## VaneL and VaneR are the two wind vanes, hinged at their origins: they open as
## the rider settles and sweep back with speed (`pose_vanes`).
## The wake (BroomWake) sheds from the stern into world space while the hero
## flies. The model is authored +Z forward and +Y up, so this node's own basis
## is the hull's (`model_root_ref`, which BroomGripModifier reads).

const DEFAULT_MODEL := "res://assets/models/props/skiffs/skiff_ashwood.gltf"
const WakeScript := preload("res://scripts/fx/broom_wake.gd")
## The soft light of the wind under the keel, by model (amber unless named).
const LIFT_TEXTURE := "res://assets/vfx/tex/soft_glow_512.png"
const LIFT_AMBER := Color(1.0, 0.62, 0.24)
const LIFT_COLORS := {
	"skiff_silverthorn": Color(0.5, 1.0, 0.8),
	"skiff_emberwing": Color(1.0, 0.38, 0.1),
	"skiff_storm": Color(0.46, 0.74, 1.0),
	"skiff_moonveil": Color(0.68, 0.82, 1.0),
}
static var _lift_mesh: QuadMesh
static var _lift_materials := {}

var mount_root: Node3D
var seat_socket: Node3D
var grip_socket: Node3D
var tail_socket: Node3D
var hand_l: Node3D
var hand_r: Node3D
var foot_l: Node3D
var foot_r: Node3D
var vane_l: Node3D
var vane_r: Node3D
var lift_socket: Node3D
var _lift: MeshInstance3D
var model_root_ref: Node3D
var model_path := ""
var _model: Node3D
var _wake: WakeScript

func _init() -> void:
	name = "BroomRig"
	model_root_ref = self

## Wear the model of broom item `item_id` (the default broom when it names
## none or its file is missing). A no-op when it already wears that model.
func use_item(item_id: String) -> void:
	var path := String(ItemRules.item(item_id).get("model", ""))
	if path == "" or not ResourceLoader.exists(path):
		path = DEFAULT_MODEL
	use_model(path)

## Wear the model at `path`; a no-op when it already wears it.
func use_model(path: String) -> void:
	if path == model_path or not ResourceLoader.exists(path):
		return
	model_path = path
	if _model != null:
		_model.queue_free()
	_model = (load(path) as PackedScene).instantiate() as Node3D
	add_child(_model)
	mount_root = _model.find_child("MountRoot", true, false) as Node3D
	seat_socket = _model.find_child("SeatSocket", true, false) as Node3D
	grip_socket = _model.find_child("GripSocket", true, false) as Node3D
	tail_socket = _model.find_child("TailSocket", true, false) as Node3D
	hand_l = _model.find_child("HandLSocket", true, false) as Node3D
	hand_r = _model.find_child("HandRSocket", true, false) as Node3D
	foot_l = _model.find_child("FootLSocket", true, false) as Node3D
	foot_r = _model.find_child("FootRSocket", true, false) as Node3D
	vane_l = _model.find_child("VaneL", true, false) as Node3D
	vane_r = _model.find_child("VaneR", true, false) as Node3D
	lift_socket = _model.find_child("LiftSocket", true, false) as Node3D
	_make_lift()
	if _wake != null:
		_wake.tail = tail_socket
		_wake.lift = lift_socket

## The glow under the keel: one soft quad facing the camera, shared per colour.
func _make_lift() -> void:
	_lift = null
	if lift_socket == null or DisplayServer.get_name() == "headless":
		return
	if _lift_mesh == null:
		_lift_mesh = QuadMesh.new()
		_lift_mesh.size = Vector2(1.5, 1.5)
	var colour: Color = LIFT_COLORS.get(model_path.get_file().get_basename(), LIFT_AMBER)
	var material: StandardMaterial3D = _lift_materials.get(colour)
	if material == null:
		material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.albedo_texture = load(LIFT_TEXTURE) as Texture2D
		material.albedo_color = Color(colour.r, colour.g, colour.b, 0.5)
		_lift_materials[colour] = material
	_lift = MeshInstance3D.new()
	_lift.name = "LiftGlow"
	_lift.mesh = _lift_mesh
	_lift.material_override = material
	_lift.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	lift_socket.add_child(_lift)

## The seat in this rig's own space (where the rider's hips go).
func seat_local() -> Vector3:
	if seat_socket == null:
		return Vector3.ZERO
	return global_transform.affine_inverse() * seat_socket.global_position

## The vanes: folded along the hull at `blend` 0, open at 1, swept back by
## `speed` (0..1 of the skiff's top speed) and stirring a little in the air.
func pose_vanes(blend: float, speed: float, time: float) -> void:
	if vane_l == null or vane_r == null:
		return
	var open := smoothstep(0.2, 1.0, blend)
	var sweep := lerpf(1.25, 0.0, open) + 0.34 * clampf(speed, 0.0, 1.0)
	var droop := lerpf(0.75, 0.0, open) + sin(time * 1.9) * 0.018
	var stir := sin(time * 3.1 + 0.8) * 0.012
	var size := Vector3.ONE * lerpf(0.25, 1.0, open)
	vane_l.rotation = Vector3(stir, sweep, -droop)
	vane_r.rotation = Vector3(stir, -sweep, droop)
	vane_l.scale = size
	vane_r.scale = size
	if _lift != null:
		var breath := 0.9 + sin(time * 2.6) * 0.07 + sin(time * 7.3) * 0.03
		_lift.scale = Vector3.ONE * open * breath * lerpf(0.8, 1.15, clampf(speed, 0.0, 1.0))

## Shed the wake while flying. It hangs beside the rig (under the hero's
## body, world placed), not inside it: the rig hides as the rider gets off,
## and the smoke already in the air should fade on its own.
func set_flying(on: bool) -> void:
	if _wake == null:
		if not on or tail_socket == null or not is_inside_tree() or DisplayServer.get_name() == "headless":
			return
		_wake = WakeScript.new()
		get_parent().add_child(_wake)
		_wake.tail = tail_socket
		_wake.lift = lift_socket
	_wake.set_flying(on)

## The wake (the dev checks read its `describe()`); null before the first flight.
func wake() -> WakeScript:
	return _wake
