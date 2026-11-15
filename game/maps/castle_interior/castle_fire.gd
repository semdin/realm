extends RefCounted

## A torch, hearth or brazier flame: one quad playing the flame_loop flipbook
## (res://assets/shaders/fire_flipbook.gdshader; the old game's FireCard).
## Every torch of the castle with the same tint and strength shares one
## material; each card's phase comes from its position.

const SHADER := preload("res://assets/shaders/fire_flipbook.gdshader")
const ATLAS := "res://assets/vfx/atlases/flame_loop_8x8_1k.png"

static var _materials: Dictionary = {}

## A flame card `size` metres (width, height) over `pos`.
static func make(parent: Node3D, pos: Vector3, size: Vector2, tint: Color = Color(1, 1, 1),
		intensity: float = 1.5) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Flame"
	var quad := QuadMesh.new()
	quad.size = size
	quad.material = material(tint, intensity)
	mi.mesh = quad
	mi.position = pos + Vector3(0, size.y * 0.12, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi

static func material(tint: Color = Color(1, 1, 1), intensity: float = 1.5) -> ShaderMaterial:
	var key := "%s/%.2f" % [tint.to_html(false), intensity]
	if _materials.has(key):
		return _materials[key]
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("flipbook", load(ATLAS))
	mat.set_shader_parameter("intensity", intensity)
	mat.set_shader_parameter("tint", tint)
	_materials[key] = mat
	return mat
