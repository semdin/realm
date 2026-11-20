extends Node
class_name HairSway

## Lets a hairstyle's tips trail the head (hero_hair_card.gdshaderinc reads
## `hair_sway`): a point over the crown is followed by a damped spring, and the
## spring's lag - where the tips would hang if they lagged behind - goes to the
## hair mesh as one instance uniform (xyz world metres, w the wind). The
## vertex shader bends each card by it, more toward the tip and on longer
## cards. One small spring per hero, nothing per strand; far away (or off
## screen) it rests.

const STIFFNESS := 60.0
const DAMPING := 8.0
## how much of the head's acceleration the tips feel (1 = a free mass)
const INERTIA := 0.5
## the most the tips trail, metres
const MAX_LAG := 0.022
## past this distance from the camera the hair stops swaying
const FAR := 25.0
## the point the spring follows: the hair's middle, over and behind the
## crown (metres up / back from the Head bone), so the head turning on its
## own axis swings it too
const CROWN_UP := 0.08
const CROWN_BACK := 0.05

var _mesh: MeshInstance3D
var _skeleton: Skeleton3D
var _head := -1
var _crown_local := Vector3.ZERO
var _last := Vector3.ZERO
var _velocity := Vector3.ZERO
var _lag := Vector3.ZERO
var _lag_velocity := Vector3.ZERO
var _primed := false
var wind := 0.15


func _ready() -> void:
	_mesh = get_parent() as MeshInstance3D
	_skeleton = _mesh.get_parent() as Skeleton3D if _mesh != null else null
	if _skeleton != null:
		_head = _skeleton.find_bone("Head")
	if _head >= 0:
		# the body faces +Z (back is FORWARD, -Z): up and back in the head
		# bone's own frame
		var rest := _skeleton.get_bone_global_rest(_head).basis.inverse()
		_crown_local = (rest * Vector3.UP) * CROWN_UP + (rest * Vector3.FORWARD) * CROWN_BACK
	set_process(_head >= 0)


func _process(delta: float) -> void:
	if delta <= 0.0 or not _mesh.is_visible_in_tree():
		return
	var crown := _skeleton.global_transform * _skeleton.get_bone_global_pose(_head) * _crown_local
	var camera := get_viewport().get_camera_3d()
	if camera != null and camera.global_position.distance_squared_to(crown) > FAR * FAR:
		_primed = false
		return
	if not _primed:
		_last = crown
		_velocity = Vector3.ZERO
		_lag = Vector3.ZERO
		_lag_velocity = Vector3.ZERO
		_primed = true
	var dt := minf(delta, 1.0 / 20.0)
	var velocity := (crown - _last) / dt
	var accel := (velocity - _velocity) / dt
	_last = crown
	_velocity = velocity
	# the tips: a damped spring pulled back by the head's own acceleration
	_lag_velocity += (-STIFFNESS * _lag - DAMPING * _lag_velocity - accel * INERTIA) * dt
	_lag += _lag_velocity * dt
	if _lag.length() > MAX_LAG:
		_lag = _lag.normalized() * MAX_LAG
		_lag_velocity *= 0.5
	var w := wind + minf(velocity.length() * 0.08, 0.6)
	_mesh.set_instance_shader_parameter("hair_sway", Vector4(_lag.x, _lag.y, _lag.z, w))
