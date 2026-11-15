extends RefCounted

## A flipbook clip standing on the ground at many points (the old game's
## StandingCards): one MultiMesh of cards that turn about Y to the camera
## (res://assets/shaders/standing_flipbook.gdshader), one draw call for a
## whole group. The light standing over a dungeon's way out.

const SHADER := preload("res://assets/shaders/standing_flipbook.gdshader")

## The card mesh and one material per clip, kept for the whole process.
static var _kept: Dictionary = {}

## Cards at `points` (in the parent's space), each `width` x `height` metres
## (both [min, max]), playing `atlas_path` (an 8x8 flipbook) at `fps`. Null
## when the clip is missing. `seed` makes the sizes and phases repeatable.
static func make(atlas_path: String, points: PackedVector3Array, width: Vector2, height: Vector2,
		fps: float, tint: Color = Color(1, 1, 1), seed: int = 1) -> MultiMeshInstance3D:
	if not _kept.has(atlas_path):
		_kept[atlas_path] = load(atlas_path) if ResourceLoader.exists(atlas_path) else null
	var atlas := _kept[atlas_path] as Texture2D
	if atlas == null or points.is_empty():
		return null
	if not _kept.has("mesh"):
		var quad := QuadMesh.new()
		quad.size = Vector2(1.0, 1.0)
		quad.center_offset = Vector3(0.0, 0.5, 0.0)   # stands on its origin
		_kept["mesh"] = quad
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("flipbook", atlas)
	material.set_shader_parameter("fps", fps)
	material.set_shader_parameter("tint", tint)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = _kept["mesh"]
	multi.instance_count = points.size()
	var reach := 0.0
	for i in points.size():
		var size := Vector3(rng.randf_range(width.x, width.y), rng.randf_range(height.x, height.y), 1.0)
		multi.set_instance_transform(i, Transform3D(Basis.from_scale(size), points[i]))
		multi.set_instance_custom_data(i, Color(rng.randf(), float(rng.randi() % 2), 0.0, 0.0))
		reach = maxf(reach, Vector2(points[i].x, points[i].z).length())
	var node := MultiMeshInstance3D.new()
	node.name = "StandingCards"
	node.multimesh = multi
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# the shader turns the cards: a box that holds them at any turn
	var span := reach + width.y
	node.custom_aabb = AABB(Vector3(-span, -2.5, -span), Vector3(span * 2.0, height.y * 2.0 + 5.0, span * 2.0))
	return node
