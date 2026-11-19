extends Node3D
class_name BroomRig

## The broom a hero rides: the equipped broom's model (items.json `model`;
## every broom GLB carries the same parts and sockets: BroomRoot > Broom_Shaft,
## Bristles, Grip/Mount/Seat/TailSocket) and the sockets the pose layers read:
##   SeatSocket - where the rider's hips sit (HeroView puts it under the hips)
##   GripSocket - the two-handed grip centre (BroomGripModifier)
##   TailSocket - the bristle tip (the cloak's shaft capsule, the wake)
## The wake (BroomWake) sheds its smoke from the tip into world space while
## the hero flies.
## The model is authored +Z forward and +Y up, so this node's own basis is the
## shaft's (`model_root_ref`, which BroomGripModifier reads).

const DEFAULT_MODEL := "res://assets/models/props/brooms/broom_ashwood.glb"
const WakeScript := preload("res://scripts/fx/broom_wake.gd")

var mount_root: Node3D
var seat_socket: Node3D
var grip_socket: Node3D
var tail_socket: Node3D
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
	if _wake != null:
		_wake.tail = tail_socket

## The seat in this rig's own space (where the rider's hips go).
func seat_local() -> Vector3:
	if seat_socket == null:
		return Vector3.ZERO
	return global_transform.affine_inverse() * seat_socket.global_position

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
	_wake.set_flying(on)

## The wake (the dev checks read its `describe()`); null before the first flight.
func wake() -> WakeScript:
	return _wake
