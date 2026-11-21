extends Control

## The death screen (CombatFeedback's): the world drained of colour and
## darkened towards the edges with a blood-dark rise from below
## (death_screen.gdshader over the whole screen, the HUD with it), and across
## the middle a dark band between two thin red lines: the title, who struck
## the blow, in a dungeon the run's death penalty and count, the two choices
## as cards (each with a ring that empties while the choice is not open yet)
## and the line running down to the automatic return.
## The prototype the owner chose: build/ui_proto/death (2026-11-21).

const SHADER := preload("res://assets/shaders/death_screen.gdshader")
const BAND_H := 372.0
const CARD := Vector2(300, 92)
const AUTO_W := 420.0
const INK := Color(0.925, 0.902, 0.875)
const MUTED := Color(0.64, 0.6, 0.57)
const BLOOD := Color(0.784, 0.204, 0.227)
const BLOOD_HI := Color(1.0, 0.353, 0.373)
const KILLER := Color(0.906, 0.639, 0.624)
const GOLD := Color(0.851, 0.722, 0.455)

var here: DeathChoice
var back: DeathChoice
var _drain: ColorRect
var _title: Label
var _cause: RichTextLabel
var _chips: HBoxContainer
var _chip_penalty: RichTextLabel
var _chip_count: RichTextLabel
var _auto_fill: ColorRect
var _auto_text: RichTextLabel
var _shown_at := 0.0

func _init() -> void:
	name = "DeathPanel"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drain = ColorRect.new()
	_drain.name = "Drain"
	_drain.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_drain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = SHADER
	_drain.material = material
	add_child(_drain)
	var band := TextureRect.new()
	band.name = "Band"
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.texture = _ramp([0.0, 0.22, 0.5, 0.78, 1.0], [0.0, 0.78, 0.84, 0.78, 0.0], Color(0.024, 0.024, 0.031), 512, 4)
	band.stretch_mode = TextureRect.STRETCH_SCALE
	band.anchor_left = 0.0
	band.anchor_right = 1.0
	band.anchor_top = 0.5
	band.anchor_bottom = 0.5
	band.offset_top = -BAND_H * 0.56
	band.offset_bottom = BAND_H * 0.44
	add_child(band)
	for edge in [band.offset_top, band.offset_bottom]:
		var line := TextureRect.new()
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.texture = _ramp([0.0, 0.3, 0.5, 0.7, 1.0], [0.0, 0.55, 0.45, 0.55, 0.0], BLOOD, 512, 1, Color(1.0, 0.86, 0.78))
		line.stretch_mode = TextureRect.STRETCH_SCALE
		line.anchor_left = 0.18
		line.anchor_right = 0.82
		line.anchor_top = 0.5
		line.anchor_bottom = 0.5
		line.offset_top = edge
		line.offset_bottom = edge + 1.0
		add_child(line)
	var column := VBoxContainer.new()
	column.name = "Column"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 0)
	column.anchor_left = 0.5
	column.anchor_right = 0.5
	column.anchor_top = 0.5
	column.anchor_bottom = 0.5
	column.offset_left = -360.0
	column.offset_right = 360.0
	column.offset_top = band.offset_top + 40.0
	column.offset_bottom = band.offset_bottom - 30.0
	add_child(column)
	# the title between two short red rules
	var title_row := HBoxContainer.new()
	title_row.alignment = BoxContainer.ALIGNMENT_CENTER
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_theme_constant_override("separation", 26)
	column.add_child(title_row)
	title_row.add_child(_rule(false))
	_title = Label.new()
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# the deco weight with wide letter spacing: the variation is copied, not
	# wrapped (a variation over a variation drops the inner one's weight)
	var deco := UITheme.font(UITheme.W_DECO)
	var title_font: FontVariation
	if deco is FontVariation:
		title_font = (deco as FontVariation).duplicate() as FontVariation
	else:
		title_font = FontVariation.new()
		title_font.base_font = deco
	title_font.spacing_glyph = 18
	_title.add_theme_font_override("font", title_font)
	_title.add_theme_font_size_override("font_size", 54)
	_title.add_theme_color_override("font_color", Color(0.945, 0.89, 0.863))
	_title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_title.add_theme_constant_override("shadow_offset_x", 0)
	_title.add_theme_constant_override("shadow_offset_y", 2)
	# a soft red light behind the letters (a glow, not an outline)
	var glow := TextureRect.new()
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.texture = _glow_texture()
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.show_behind_parent = true
	glow.set_anchors_preset(Control.PRESET_CENTER)
	glow.offset_left = -300
	glow.offset_right = 300
	glow.offset_top = -56
	glow.offset_bottom = 56
	_title.add_child(glow)
	title_row.add_child(_title)
	title_row.add_child(_rule(true))
	_cause = _rich(17, MUTED)
	_cause.custom_minimum_size = Vector2(720, 30)
	column.add_child(_gap(8))
	column.add_child(_cause)
	_chips = HBoxContainer.new()
	_chips.alignment = BoxContainer.ALIGNMENT_CENTER
	_chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chips.add_theme_constant_override("separation", 10)
	_chip_penalty = _chip()
	_chip_count = _chip()
	column.add_child(_gap(8))
	column.add_child(_chips)
	column.add_child(_gap(26))
	var cards := HBoxContainer.new()
	cards.name = "DeathChoices"
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("separation", 18)
	column.add_child(cards)
	here = DeathChoice.new()
	here.name = "ReviveHere"
	here.picture = UITheme.icon_for("stat_health")
	here.halo = Color(1.0, 0.47, 0.43)
	cards.add_child(here)
	back = DeathChoice.new()
	back.name = "ReviveTown"
	back.picture = UITheme.icon_for("ui_portal")
	back.halo = Color(0.55, 0.7, 1.0)
	cards.add_child(back)
	column.add_child(_gap(24))
	var auto := VBoxContainer.new()
	auto.mouse_filter = Control.MOUSE_FILTER_IGNORE
	auto.alignment = BoxContainer.ALIGNMENT_CENTER
	auto.add_theme_constant_override("separation", 8)
	auto.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	auto.custom_minimum_size = Vector2(AUTO_W, 0)
	column.add_child(auto)
	var track := ColorRect.new()
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.color = Color(1, 1, 1, 0.08)
	track.custom_minimum_size = Vector2(AUTO_W, 2)
	auto.add_child(track)
	_auto_fill = ColorRect.new()
	_auto_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_auto_fill.color = Color(1.0, 0.55, 0.47, 0.8)
	_auto_fill.size = Vector2(AUTO_W, 2)
	track.add_child(_auto_fill)
	_auto_text = _rich(13, MUTED)
	_auto_text.custom_minimum_size = Vector2(AUTO_W, 20)
	auto.add_child(_auto_text)

func open() -> void:
	_shown_at = Time.get_ticks_msec() / 1000.0
	show()

func _process(_delta: float) -> void:
	if not visible:
		return
	# the world drains over the first second
	var t := Time.get_ticks_msec() / 1000.0 - _shown_at
	(_drain.material as ShaderMaterial).set_shader_parameter("amount", smoothstep(0.0, 1.0, t))

## The texts: the title, who struck the blow ("" leaves the line out), in a
## dungeon the penalty and this run's death count (penalty 0: no chips).
func set_story(title: String, cause: String, penalty_text: String, count_text: String) -> void:
	_title.text = title
	_cause.text = "[center]%s[/center]" % cause
	_cause.visible = cause != ""
	_chips.visible = penalty_text != "" or count_text != ""
	_chip_penalty.get_parent().visible = penalty_text != ""
	_chip_penalty.text = penalty_text
	_chip_count.get_parent().visible = count_text != ""
	_chip_count.text = count_text

## The automatic return: `left` of `total` seconds, and its line of text.
func set_auto(left: float, total: float, text: String) -> void:
	_auto_fill.size.x = AUTO_W * clampf(left / maxf(total, 1.0), 0.0, 1.0)
	_auto_text.text = "[center]%s[/center]" % text

func _rule(flip: bool) -> TextureRect:
	var rule := TextureRect.new()
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.texture = _ramp([0.0, 1.0], [0.0, 1.0], BLOOD, 128, 1)
	rule.stretch_mode = TextureRect.STRETCH_SCALE
	rule.flip_h = flip
	rule.custom_minimum_size = Vector2(120, 1)
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return rule

func _rich(size: int, colour: Color) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("normal_font", UITheme.font(UITheme.W_BODY))
	label.add_theme_font_override("bold_font", UITheme.font(UITheme.W_BOLD))
	label.add_theme_font_size_override("normal_font_size", size)
	label.add_theme_font_size_override("bold_font_size", size)
	label.add_theme_color_override("default_color", colour)
	return label

func _chip() -> RichTextLabel:
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.035)
	style.border_color = Color(1, 1, 1, 0.09)
	style.set_border_width_all(1)
	style.set_corner_radius_all(999)
	style.content_margin_left = 11
	style.content_margin_right = 11
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	box.add_theme_stylebox_override("panel", style)
	var label := _rich(13, Color(0.85, 0.81, 0.78))
	label.fit_content = true
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	box.add_child(label)
	_chips.add_child(box)
	return label

## A soft oval of red light (the title's glow).
static func _glow_texture() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	gradient.colors = PackedColorArray([Color(0.78, 0.13, 0.16, 0.34), Color(0.6, 0.08, 0.1, 0.12), Color(0.5, 0.05, 0.08, 0.0)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.width = 256
	texture.height = 64
	return texture

static func _gap(h: float) -> Control:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, h)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return gap

## A horizontal ramp of `colour` (alpha by `alphas` at `offsets`), towards
## `centre` in the middle when given.
static func _ramp(offsets: Array, alphas: Array, colour: Color, w: int, h: int, centre := Color(0, 0, 0, 0)) -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array(offsets)
	var colours := PackedColorArray()
	for i in offsets.size():
		var c := colour
		if centre.a > 0.0 and absf(float(offsets[i]) - 0.5) < 0.01:
			c = centre
		c.a = float(alphas[i])
		colours.append(c)
	gradient.colors = colours
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = w
	texture.height = h
	return texture


## A choice card: dark glass with a lit top line, the picture in a ring of its
## own colour, a title and a line under it; greyed with a ring emptying round
## the picture (and the seconds in it) while the choice is not open yet.
class DeathChoice extends Button:
	const CARD := Vector2(300, 92)
	const INK := Color(0.925, 0.902, 0.875)
	const MUTED := Color(0.64, 0.6, 0.57)
	const GOLD := Color(0.851, 0.722, 0.455)
	var picture: Texture2D
	var halo := Color.WHITE
	## Drawn here (not the Button's own text, which the flat button would draw
	## under it).
	var title := ""
	var line := ""
	## 0..1 of the wait still to go (0: open) and the seconds shown.
	var wait_share := 0.0
	var wait_seconds := 0

	func _init() -> void:
		custom_minimum_size = CARD
		focus_mode = Control.FOCUS_NONE
		flat = true
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		for state in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
			add_theme_stylebox_override(state, StyleBoxEmpty.new())
		mouse_entered.connect(queue_redraw)
		mouse_exited.connect(queue_redraw)

	func set_wait(share: float, seconds: int) -> void:
		if share != wait_share or seconds != wait_seconds:
			wait_share = share
			wait_seconds = seconds
			queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var lift := -2.0 if is_hovered() and not disabled else 0.0
		r.position.y += lift
		var glass := StyleBoxFlat.new()
		glass.bg_color = Color(0.039, 0.043, 0.055, 0.78)
		glass.border_color = Color(0.851, 0.722, 0.455, 0.55) if is_hovered() and not disabled else Color(1, 1, 1, 0.09)
		glass.set_border_width_all(1)
		glass.set_corner_radius_all(4)
		glass.shadow_color = Color(0, 0, 0, 0.45)
		glass.shadow_size = 14
		glass.shadow_offset = Vector2(0, 8)
		draw_style_box(glass, r)
		# the lit top line
		draw_rect(Rect2(r.position + Vector2(4, 1), Vector2(r.size.x - 8, 1)), Color(1, 1, 1, 0.09))
		var off := disabled
		var c := r.position + Vector2(18 + 27, r.size.y * 0.5)
		draw_circle(c, 27.0, Color(0, 0, 0, 0.4))
		draw_arc(c, 27.5, 0.0, TAU, 48, Color(halo, 0.35 if not off else 0.12), 1.0, true)
		if picture != null:
			var pic := Rect2(c - Vector2(20, 20), Vector2(40, 40))
			draw_texture_rect(UITheme.drawn_pixels(picture, 40.0, self), pic, false, Color(1, 1, 1, 0.38) if off else Color.WHITE)
		if off and wait_share > 0.0:
			draw_arc(c, 29.0, -PI * 0.5, -PI * 0.5 + TAU * wait_share, 48, GOLD, 2.5, true)
			var f := UITheme.font(UITheme.W_DECO)
			var txt := str(wait_seconds)
			var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
			draw_string_outline(f, c + Vector2(-w * 0.5, 7), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, 4, Color(0, 0, 0, 0.9))
			draw_string(f, c + Vector2(-w * 0.5, 7), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)
		var x := r.position.x + 18 + 54 + 16
		var bold := UITheme.font(UITheme.W_BOLD)
		var body := UITheme.font(UITheme.W_BODY)
		var ink := Color(INK, 0.38 if off else 1.0)
		var muted := Color(MUTED, 0.38 if off else 1.0)
		draw_string(bold, Vector2(x, r.position.y + r.size.y * 0.5 - 4), title, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - x - 10, 17, ink)
		draw_string(body, Vector2(x, r.position.y + r.size.y * 0.5 + 18), line, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - x - 10, 13, muted)

