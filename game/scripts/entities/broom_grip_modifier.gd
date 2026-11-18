extends SkeletonModifier3D
class_name BroomGripModifier

## Seat the rider in the skiff after the animated pose and cast layer: the feet
## on the floor of the well, the back in a riding lean, the hands on the helm bar.
## Bone poses are temporary inside this pass: never reapply them deferred.
const LEAN_SHARE := {"Spine": 0.5, "Chest": 0.3, "UpperChest": 0.2}
## The rider's spine (hips -> neck) may lean anywhere in this band; each broom
## clip authors its own lean (sitting up to brake, flat to dive) and the solver
## only pulls it back inside the band, where the hands can still reach the wood.
const LEAN_MIN_DEG := 22.0
const LEAN_MAX_DEG := 48.0
## Where the hands hold the shaft, measured forward from the seat along it.
## (GripSocket sits 0.55 m ahead, out of reach of an upright rider.)
const GRIP_AHEAD := 0.38
const GRIP_SPREAD := 0.065
const PALM_DEPTH := 0.039
# The imported shaft curves above its socket baseline: the wood rings in the
# grip region are centred 4.2-4.8 cm above GripSocket (build_broom.py).
const SHAFT_RISE := 0.045

## The foot rests this far toe-down from level on the boards.
const FOOT_PITCH_DEG := 16.0
const LEGS := [
	{"side": "L", "root": "LeftUpperLeg", "mid": "LeftLowerLeg", "end": "LeftFoot", "toes": "LeftToes", "out": 1.0},
	{"side": "R", "root": "RightUpperLeg", "mid": "RightLowerLeg", "end": "RightFoot", "toes": "RightToes", "out": -1.0},
]
const ARMS := [
	{"side": "L", "root": "LeftUpperArm", "mid": "LeftLowerArm", "end": "LeftHand", "offset": -GRIP_SPREAD},
	{"side": "R", "root": "RightUpperArm", "mid": "RightLowerArm", "end": "RightHand", "offset": GRIP_SPREAD},
]

## The broom rig to solve onto (a BroomFlight). Set once by player.gd.
var broom: Node = null
## 0..1, driven from the player's mount blend; 0 hands the body back to the clips.
var target_weight := 0.0
var weight := 0.0

var _bases := {}
var _hand_error := 0.0
var _hand_alignment := 1.0


func setup(broom_rig: Node) -> void:
	broom = broom_rig


## Distance from the worst palm grip centre to the shaft, in metres.
func hand_error() -> float:
	return _hand_error if weight > 0.5 else -1.0

## Alignment of the handle axis across each palm with the shaft.
func hand_alignment() -> float:
	return _hand_alignment if weight > 0.5 else -1.0

func engaged() -> bool:
	return weight > 0.5


func _process_modification_with_delta(delta: float) -> void:
	weight = move_toward(weight, clampf(target_weight, 0.0, 1.0), delta * 3.2)
	var skeleton := get_skeleton()
	if skeleton == null or weight <= 0.001:
		return
	_capture_bases(skeleton)
	_seat_legs(skeleton)
	_lean(skeleton)
	for side in ["L", "R"]:
		RigIK.close_hand(skeleton, side, weight, PALM_DEPTH)
	_grip(skeleton)


## Remember what the animation (and the cast layer, which runs before us) wrote.
func _capture_bases(skeleton: Skeleton3D) -> void:
	_bases.clear()
	for bone in LEAN_SHARE:
		var index := RigIK.bone_index(skeleton, bone)
		if index >= 0:
			_bases[index] = skeleton.get_bone_pose_rotation(index)
	for name in ["Neck", "Head"]:
		var index := RigIK.bone_index(skeleton, name)
		if index >= 0:
			_bases[index] = skeleton.get_bone_pose_rotation(index)
	for arm in ARMS:
		for key in ["root", "mid", "end"]:
			var index := RigIK.bone_index(skeleton, String(arm[key]))
			if index >= 0:
				_bases[index] = skeleton.get_bone_pose_rotation(index)
	for leg in LEGS:
		for key in ["root", "mid", "end"]:
			var index := RigIK.bone_index(skeleton, String(leg[key]))
			if index >= 0:
				_bases[index] = skeleton.get_bone_pose_rotation(index)
	skeleton.force_update_all_bone_transforms()


## Put each ankle on its socket with the knee up and a little out, the foot flat
## on the boards. Worked out from the one set of global poses and written
## without a skeleton update (the hips do not move here): riders are many.
func _seat_legs(skeleton: Skeleton3D) -> void:
	if broom == null or not is_instance_valid(broom):
		return
	var foot_l: Node3D = broom.get("foot_l")
	var foot_r: Node3D = broom.get("foot_r")
	var model: Node3D = broom.get("model_root_ref")
	if foot_l == null or foot_r == null or model == null:
		return
	var to_local: Transform3D = skeleton.global_transform.affine_inverse()
	var forward: Vector3 = (to_local.basis * model.global_basis.z).normalized()
	var up: Vector3 = (to_local.basis * model.global_basis.y).normalized()
	var left: Vector3 = up.cross(forward).normalized()
	var pitch := deg_to_rad(FOOT_PITCH_DEG)
	var toe_line := (forward * cos(pitch) - up * sin(pitch)).normalized()
	for leg in LEGS:
		var root := RigIK.bone_index(skeleton, String(leg["root"]))
		var mid := RigIK.bone_index(skeleton, String(leg["mid"]))
		var end := RigIK.bone_index(skeleton, String(leg["end"]))
		var toes := RigIK.bone_index(skeleton, String(leg["toes"]))
		if root < 0 or mid < 0 or end < 0:
			continue
		var socket: Node3D = foot_l if String(leg["side"]) == "L" else foot_r
		var target: Vector3 = to_local * socket.global_position
		var root_pose := skeleton.get_bone_global_pose(root)
		var mid_pose := skeleton.get_bone_global_pose(mid)
		var end_pose := skeleton.get_bone_global_pose(end)
		var hip := root_pose.origin
		var knee_now := mid_pose.origin
		var ankle_now := end_pose.origin
		var thigh := hip.distance_to(knee_now)
		var shin := knee_now.distance_to(ankle_now)
		var toward := target - hip
		if thigh < 0.001 or shin < 0.001 or toward.length_squared() < 1e-6:
			continue
		var axis := toward.normalized()
		var pole := forward * 0.8 + up * 0.5 + left * float(leg["out"]) * 0.3
		pole = (pole - axis * pole.dot(axis)).normalized()
		var span := clampf(toward.length(), absf(thigh - shin) + 1e-3, thigh + shin - 1e-3)
		var along := (thigh * thigh + span * span - shin * shin) / (2.0 * span)
		var knee := hip + axis * along + pole * sqrt(maxf(0.0, thigh * thigh - along * along))
		var ankle_goal := hip + axis * span
		var turn_thigh := Quaternion((knee_now - hip).normalized(), (knee - hip).normalized())
		var ankle_moved: Vector3 = hip + turn_thigh * (ankle_now - hip)
		var turn_shin := Quaternion((ankle_moved - knee).normalized(), (ankle_goal - knee).normalized())
		var turned := turn_shin * turn_thigh
		var parent := skeleton.get_bone_parent(root)
		var parent_rotation := Quaternion()
		if parent >= 0:
			parent_rotation = skeleton.get_bone_global_pose(parent).basis.orthonormalized().get_rotation_quaternion()
		var thigh_rotation := turn_thigh * root_pose.basis.orthonormalized().get_rotation_quaternion()
		var shin_rotation := turned * mid_pose.basis.orthonormalized().get_rotation_quaternion()
		var foot_rotation := turned * end_pose.basis.orthonormalized().get_rotation_quaternion()
		if toes >= 0:
			var toe_now: Vector3 = turned * (skeleton.get_bone_global_pose(toes).origin - ankle_now)
			foot_rotation = Quaternion(toe_now.normalized(), toe_line) * foot_rotation
		_write_leg(skeleton, root, parent_rotation.inverse() * thigh_rotation)
		_write_leg(skeleton, mid, thigh_rotation.inverse() * shin_rotation)
		_write_leg(skeleton, end, shin_rotation.inverse() * foot_rotation)


func _write_leg(skeleton: Skeleton3D, bone: int, wanted: Quaternion) -> void:
	var base: Quaternion = _bases[bone]
	skeleton.set_bone_pose_rotation(bone, base.slerp(wanted.normalized(), weight))


## Aim the spine at an absolute riding lean. Adding a fixed angle to each
## authored clip over-bends dives and under-bends the driving-derived idle.
func _lean(skeleton: Skeleton3D) -> void:
	var shaft := _shaft(skeleton)
	if shaft.is_empty():
		return
	var hips := RigIK.bone_index(skeleton, "Hips")
	var neck := RigIK.bone_index(skeleton, "Neck")
	var up: Vector3 = shaft["up"]
	var forward: Vector3 = shaft["direction"]
	for _iteration in range(5):
		var current := (skeleton.get_bone_global_pose(neck).origin - skeleton.get_bone_global_pose(hips).origin).normalized()
		var lean := atan2(current.dot(forward), current.dot(up))
		var clamped := clampf(lean, deg_to_rad(LEAN_MIN_DEG), deg_to_rad(LEAN_MAX_DEG))
		# Lean only as far as the hands need to reach the wood.
		var deficit := _reach_deficit(skeleton, shaft)
		if deficit > 0.0:
			clamped = minf(deg_to_rad(LEAN_MAX_DEG), maxf(clamped, lean + deficit * 1.4))
		if absf(clamped - lean) < 0.002:
			break
		# Keep the clip's sideways (bank) component; correct only the forward lean.
		var lateral := current - up * current.dot(up) - forward * current.dot(forward)
		var in_plane := sqrt(maxf(0.0, 1.0 - lateral.length_squared()))
		var wanted := lateral + (up * cos(clamped) + forward * sin(clamped)) * in_plane
		var correction := Quaternion(current, wanted.normalized())
		for bone in LEAN_SHARE:
			var index := RigIK.bone_index(skeleton, bone)
			if index >= 0:
				RigIK.rotate_global(skeleton, index, Quaternion.IDENTITY.slerp(correction, float(LEAN_SHARE[bone]) * weight), 1.0)
	# Keep the gaze ahead of the broom. Both joints start from the rig's rest
	# orientation rather than inheriting the driving clip's neck twists.
	var upright := Basis(up.cross(forward), up, forward).orthonormalized()
	for bone in ["Neck", "Head"]:
		var index := RigIK.bone_index(skeleton, bone)
		var parent := skeleton.get_bone_parent(index)
		var global_basis := upright * skeleton.get_bone_global_rest(index).basis.orthonormalized()
		var local := skeleton.get_bone_global_pose(parent).basis.orthonormalized().inverse() * global_basis
		RigIK.write_rotation(skeleton, index, local.get_rotation_quaternion(), weight, _bases[index])


## How far (m) the farther hand's grip point is beyond what that arm can reach
## from where its shoulder is now; 0 when both hands can hold the shaft.
func _reach_deficit(skeleton: Skeleton3D, shaft: Dictionary) -> float:
	var worst := 0.0
	for arm in ARMS:
		var root := RigIK.bone_index(skeleton, String(arm["root"]))
		var mid := RigIK.bone_index(skeleton, String(arm["mid"]))
		var end := RigIK.bone_index(skeleton, String(arm["end"]))
		if root < 0 or mid < 0 or end < 0:
			continue
		var shoulder := skeleton.get_bone_global_pose(root).origin
		var elbow := skeleton.get_bone_global_pose(mid).origin
		var wrist := skeleton.get_bone_global_pose(end).origin
		var palm := RigIK.grip_frame(skeleton, String(arm["side"]), PALM_DEPTH).origin.length()
		# Keep a little bend in the elbow: 96% of the straight-arm reach.
		var reach := (shoulder.distance_to(elbow) + elbow.distance_to(wrist) + palm) * 0.96
		var target := _palm_point(shaft, arm)
		worst = maxf(worst, shoulder.distance_to(target) - reach)
	return worst


## Where this arm's palm goes: its end of the helm bar, or on a straight shaft
## its place along the wood.
func _palm_point(shaft: Dictionary, arm: Dictionary) -> Vector3:
	if shaft.has("hands"):
		return (shaft["hands"] as Dictionary)[String(arm["side"])]
	return shaft["hold"] + (shaft["direction"] as Vector3) * float(arm["offset"])


## Match the palm's full frame to the handle, then solve the wrist position.
## Aligning only the forearm direction leaves the palm rolled away from the wood.
func _grip(skeleton: Skeleton3D) -> void:
	var shaft := _shaft(skeleton)
	if shaft.is_empty():
		_hand_error = -1.0
		return
	var direction: Vector3 = shaft["direction"]
	_hand_error = 0.0
	_hand_alignment = 1.0
	for arm in ARMS:
		var root := RigIK.bone_index(skeleton, String(arm["root"]))
		var mid := RigIK.bone_index(skeleton, String(arm["mid"]))
		var end := RigIK.bone_index(skeleton, String(arm["end"]))
		if root < 0 or mid < 0 or end < 0:
			continue
		var shoulder := skeleton.get_bone_global_pose(root).origin
		var palm_point := _palm_point(shaft, arm)
		# The handle's line through this palm: across the helm bar, index
		# fingers toward the middle; along a straight shaft, both forward.
		var across: Vector3 = direction
		if shaft.has("bar"):
			across = (shaft["bar"] as Vector3) * (-1.0 if String(arm["side"]) == "L" else 1.0)
		var down := palm_point - shoulder
		down = (down - across * down.dot(across)).normalized()
		var grip := RigIK.grip_frame(skeleton, String(arm["side"]), PALM_DEPTH)
		# grip_frame already mirrors the palm normal.
		var wanted := Basis(across, down, across.cross(down)).orthonormalized() * grip.basis.inverse()
		var target := palm_point - wanted * grip.origin
		RigIK.two_bone(skeleton, root, mid, end, target, Vector3.DOWN, weight, _bases)
		var parent := skeleton.get_bone_parent(end)
		var local := skeleton.get_bone_global_pose(parent).basis.orthonormalized().inverse() * wanted
		RigIK.write_rotation(skeleton, end, local.get_rotation_quaternion(), weight, _bases[end])
		var wrist := skeleton.get_bone_global_pose(end)
		_hand_error = maxf(_hand_error, RigIK.distance_to_line(wrist * grip.origin, palm_point, across))
		_hand_alignment = minf(_hand_alignment, absf((wrist.basis * grip.basis.x).normalized().dot(across)))


## The shaft's centreline in skeleton space: the SeatSocket projecting onto it,
## including the authored wood curvature above the socket baseline.
func _shaft(skeleton: Skeleton3D) -> Dictionary:
	if broom == null or not is_instance_valid(broom):
		return {}
	var seat_socket = broom.get("seat_socket")
	var grip_socket = broom.get("grip_socket")
	if seat_socket == null or grip_socket == null:
		return {}
	var to_local: Transform3D = skeleton.global_transform.affine_inverse()
	var seat: Vector3 = to_local * (seat_socket as Node3D).global_position
	var grip: Vector3 = to_local * (grip_socket as Node3D).global_position
	var model = broom.get("model_root_ref")
	var up := Vector3.UP
	# The broom is authored +Z forward (broom_flight.verify_axes measures exactly
	# that), so its own forward IS the shaft axis. Deriving the axis from the two
	# sockets instead would tilt it: the grip socket sits 0.18 m BELOW the seat as
	# well as ahead of it, so seat -> grip is 18 deg off the shaft.
	var direction := grip - seat
	if model is Node3D:
		direction = to_local.basis * (model as Node3D).global_basis.z
		up = (to_local.basis * (model as Node3D).global_basis.y).normalized()
	if direction.length_squared() < 1e-6:
		return {}
	direction = direction.normalized()
	# The seat sits `drop` above the centreline.
	var drop := absf((seat_socket as Node3D).position.y - (grip_socket as Node3D).position.y)
	var origin := seat - up * (drop - SHAFT_RISE)
	var out := {"origin": origin, "direction": direction,
		"up": up, "grip": grip + up * SHAFT_RISE, "hold": origin + direction * GRIP_AHEAD}
	var hand_l: Node3D = broom.get("hand_l")
	var hand_r: Node3D = broom.get("hand_r")
	if hand_l != null and hand_r != null:
		var left: Vector3 = to_local * hand_l.global_position
		var right: Vector3 = to_local * hand_r.global_position
		out["hands"] = {"L": left, "R": right}
		out["bar"] = (left - right).normalized()
		out["hold"] = (left + right) * 0.5
	return out
