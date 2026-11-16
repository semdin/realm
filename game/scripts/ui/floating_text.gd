extends Node3D
class_name FloatingText

## A damage number (or a short word) that rises from where it was spawned,
## drifts a little sideways, slows and fades out over a second. One billboard
## Label3D, drawn over bodies (a number inside a troll is no use), freed when
## it has faded.
##
## A damage number (`number`) keeps one size on screen however far the
## camera is (the label's fixed_size: no work of ours per frame): a share of
## the screen's height, larger for a critical hit. A word (`spawn`) keeps its
## world size.

## A damage number's letters, as a share of the screen's height at scale 1
## (about 31 px at 900 px), and the label's pixel size that gives it with the
## camera's 75-degree view: font_size * pixel_size = share * 2 tan(37.5).
const NUMBER_SCREEN_SHARE := 0.035
const NUMBER_FONT_SIZE := 48
const NUMBER_PIXEL_SIZE := NUMBER_SCREEN_SHARE * 1.5346 / NUMBER_FONT_SIZE

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

## A damage number at `at` (world space): the same size on screen at any
## distance, `scale_mult` times the plain number's.
static func number(parent: Node, at: Vector3, text: String, color: Color, scale_mult := 1.0) -> FloatingText:
	var ft := FloatingText.new()
	ft.label.fixed_size = true
	ft.label.font = UITheme.world_font(UITheme.W_BOLD)
	ft.label.font_size = NUMBER_FONT_SIZE
	ft.label.outline_size = 12
	ft.label.pixel_size = NUMBER_PIXEL_SIZE
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
