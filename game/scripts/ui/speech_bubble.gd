extends Node3D
class_name SpeechBubble

## What a player says in local chat, floating over their head for LIFETIME
## seconds and fading over the last FADE (the old game's approved bubble). One
## per speaker: a new line replaces the old one.
##
## The card is a 2D control on its own screen layer, pinned each frame over
## this node's projected position (its tail's tip on the anchor), so it is
## never tonemapped, fogged or tinted by what stands behind it; it shrinks a
## little with distance and hides beyond RANGE or behind the camera.

const LIFETIME := 6.0
const FADE := 0.6
## The widest the card's text runs before it wraps.
const MAX_WIDTH := 300.0
## Over a speaker's feet.
const HEIGHT := 2.62
const RANGE := 55.0
const REF_DISTANCE := 7.0
const FONT_SIZE := 15
const PAPER := Color(0.98, 0.96, 0.90, 1.0)
const EDGE := Color(0.36, 0.26, 0.12)
const TAIL := 9.0

## What it says (the checks read it).
var text := ""
## 0..1 opacity: the last FADE seconds fade it out.
var fade := 1.0
var _age := 0.0
var _layer: CanvasLayer
var _root: Control
var _card: PanelContainer
var _tail_built := false

## `speaker` says `line`: its bubble (replacing one it already has), or null
## for an empty line.
static func say(speaker: Node3D, line: String, height := HEIGHT) -> SpeechBubble:
	if speaker == null or not is_instance_valid(speaker) or line.strip_edges() == "":
		return null
	var old := speaker.get_node_or_null("SpeechBubble")
	if old != null:
		old.name = "SpeechBubbleOld"
		old.queue_free()
	var bubble := SpeechBubble.new()
	bubble.name = "SpeechBubble"
	bubble.text = line.strip_edges().substr(0, 140)
	speaker.add_child(bubble)
	bubble.position = Vector3(0, height, 0)
	return bubble

func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 0
	add_child(_layer)
	_root = Control.new()
	_root.name = "SpeechCard"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	_layer.add_child(_root)
	_card = PanelContainer.new()
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = PAPER
	sb.border_color = EDGE
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 5
	sb.content_margin_bottom = 6
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 4
	sb.shadow_offset = Vector2(0, 2)
	_card.add_theme_stylebox_override("panel", sb)
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", HudKit.bold())
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.add_theme_color_override("font_color", Color(0.10, 0.07, 0.04))
	var one_line := HudKit.bold().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	label.custom_minimum_size.x = minf(one_line + 2.0, MAX_WIDTH)
	_card.add_child(label)
	_root.add_child(_card)

## The tail under the card, once the card has its laid-out size.
func _build_tail() -> void:
	var s := _card.get_combined_minimum_size()
	if s.y <= 0.0:
		return
	_tail_built = true
	_card.size = s
	_root.size = Vector2(s.x, s.y + TAIL)
	var cx := s.x * 0.5
	var tail := Polygon2D.new()
	tail.polygon = PackedVector2Array([Vector2(cx - 8, s.y - 2), Vector2(cx + 8, s.y - 2), Vector2(cx, s.y + TAIL)])
	tail.color = PAPER
	_root.add_child(tail)
	var edge := Line2D.new()
	edge.points = PackedVector2Array([Vector2(cx - 8, s.y - 0.5), Vector2(cx, s.y + TAIL), Vector2(cx + 8, s.y - 0.5)])
	edge.width = 2.0
	edge.default_color = EDGE
	_root.add_child(edge)

func _process(delta: float) -> void:
	_age += delta
	fade = clampf((LIFETIME - _age) / FADE, 0.0, 1.0)
	if _age >= LIFETIME:
		queue_free()
		return
	if not _tail_built:
		_build_tail()
	var cam := get_viewport().get_camera_3d()
	var at := global_position
	var shown := _tail_built and cam != null and not cam.is_position_behind(at) and is_visible_in_tree()
	var distance := cam.global_position.distance_to(at) if cam != null else 0.0
	shown = shown and distance <= RANGE
	_root.visible = shown
	if not shown:
		return
	var p := cam.unproject_position(at)
	var s := clampf(REF_DISTANCE / maxf(distance, 0.01), 0.72, 1.0)
	_root.scale = Vector2(s, s)
	_root.pivot_offset = Vector2(_root.size.x * 0.5, _root.size.y)
	_root.position = p - Vector2(_root.size.x * 0.5, _root.size.y)
	_root.modulate.a = fade
