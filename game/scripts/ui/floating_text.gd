extends Node3D
class_name FloatingText

## A damage number (or a short word) that rises from where it was spawned,
## drifts a little sideways, slows and fades out over a second. One billboard
## Label3D, drawn over bodies (a number inside a troll is no use), freed when
## it has faded.

var label: Label3D
var velocity := Vector3(0, 2.5, 0)
var duration := 1.0
var elapsed := 0.0

## Adds a number to `parent` at `at` (world space).
static func spawn(parent: Node, at: Vector3, text: String, color: Color = Color.WHITE, scale_mult := 1.0) -> FloatingText:
	var ft := FloatingText.new()
	parent.add_child(ft)
	ft.global_position = at
	ft.setup(text, color, scale_mult)
	return ft

func _init() -> void:
	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.double_sided = false
	label.no_depth_test = true
	label.font_size = 40
	label.outline_size = 10
	label.outline_modulate = Color(0, 0, 0, 1)
	add_child(label)

func setup(text: String, color: Color = Color.WHITE, scale_mult := 1.0) -> void:
	label.text = text
	label.modulate = color
	label.scale = Vector3.ONE * scale_mult
	velocity.x = randf_range(-0.8, 0.8)
	velocity.z = randf_range(-0.8, 0.8)

func _process(delta: float) -> void:
	elapsed += delta
	position += velocity * delta
	velocity.y -= 1.5 * delta
	if elapsed >= duration:
		queue_free()
	else:
		label.modulate.a = 1.0 - elapsed / duration
		label.outline_modulate.a = label.modulate.a
