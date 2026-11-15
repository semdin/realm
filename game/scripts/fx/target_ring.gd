extends MeshInstance3D
class_name TargetRing

## The mark on the ground under the current target (the old game's
## TargetRing): a ring of energy cut from the spell effects' cloud map
## (target_ring.gdshader) with a few sparks lifting off it. It closes in from
## wide when a target is taken and is sized to the target: a boss's is wide.
## Gold for creatures and objects, violet for a boss, pale blue for another
## player. main.gd hands it the target each frame (`follow`).
##
## The mesh is only a box round the target's feet: the shader draws the ring
## on the ground it finds inside it, so it lies on a slope.

const SHADER := "res://assets/shaders/target_ring.gdshader"
const NOISE := "res://assets/vfx/tex/noise_erosion_512.png"
const GOLD := Color(1.0, 0.74, 0.28, 1.0)
## A boss's ring is violet: it stands inside the boss's own warnings, which
## burn orange.
const BOSS := Color(0.72, 0.40, 1.0, 1.0)
const ALLY := Color(0.42, 0.72, 1.0, 1.0)
const BOX_PER_RADIUS := 1.8
const HALF_HEIGHT := 0.7
const SNAP_S := 0.26

var _material: ShaderMaterial
var _box: BoxMesh
var _motes: GPUParticles3D = null
var _snap := 0.0
## The entity the ring is under (0 = none) and how it was dressed.
var target := 0
var radius := 0.0
var tint := GOLD

func _ready() -> void:
	name = "TargetRing"
	_box = BoxMesh.new()
	_box.size = Vector3(2.0, HALF_HEIGHT * 2.0, 2.0)
	mesh = _box
	_material = ShaderMaterial.new()
	_material.shader = SpellEffect.asset(SHADER) as Shader
	_material.set_shader_parameter("half_height", HALF_HEIGHT)
	_material.set_shader_parameter("noise", SpellEffect.asset(NOISE))
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	top_level = true
	visible = false

## Under entity `id` standing at `feet` (0: none), `ring_radius` metres wide
## in `colour`; a new target closes in from wide.
func follow(id: int, feet: Vector3, ring_radius: float, colour: Color) -> void:
	if id != target or not is_equal_approx(ring_radius, radius) or colour != tint:
		var fresh := id != target
		target = id
		if id != 0:
			_dress(ring_radius, colour)
			if fresh:
				_snap = 1.0
	visible = id != 0
	if id == 0:
		return
	global_position = feet

func _process(delta: float) -> void:
	if _snap > 0.0:
		_snap = maxf(0.0, _snap - delta / SNAP_S)
		_material.set_shader_parameter("snap", _snap)

func _dress(ring_radius: float, colour: Color) -> void:
	radius = ring_radius
	tint = colour
	_box.size = Vector3(ring_radius * BOX_PER_RADIUS * 2.0, HALF_HEIGHT * 2.0, ring_radius * BOX_PER_RADIUS * 2.0)
	_material.set_shader_parameter("radius", ring_radius)
	_material.set_shader_parameter("tint", colour)
	if _motes != null and is_instance_valid(_motes):
		_motes.queue_free()
	_motes = RisingMotes.make(ring_radius, 4.0, colour, 8 + int(ring_radius * 5.0), 1.5, Vector2(0.12, 0.55),
		Vector2(0.007, 0.016))
	add_child(_motes)
	_motes.emitting = true

## The ring's radius for a creature of `species` (a boss wide, an object by
## its body, the rest by their height).
static func radius_for(species: String, boss: bool) -> float:
	if boss:
		return 2.6
	var view := CreatureView.view_of(species)
	if view.has("body_radius"):
		return clampf(float(view["body_radius"]) * 1.7, 1.0, 3.0)
	return clampf(float(view.get("label_height", 2.3)) * 0.33, 1.0, 2.2)
